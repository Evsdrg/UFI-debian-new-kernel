// SPDX-License-Identifier: GPL-2.0-only
/*
 * mf601sl-ledctl.c — MF601SL 状态灯与电源键守护进程
 *
 * 硬件（2026-11-01 用户实机确认方位）：6 颗灯，两两一组，共三组。
 * 以充电口朝下为基准：
 *   左上  LTE   红=GPIO115 (red:wan)    绿=GPIO116 (green:wan)
 *   右上  电量  红=GPIO110 (red:power)  绿=GPIO112 (green:power)
 *   右下  WiFi  红=GPIO119 (red:wlan)   绿=GPIO120 (green:wlan)
 *
 * 灯语：
 *   电量组  默认灭；短按 peek 3 秒。绿=有电，红=低电(<=20%)；充电中绿闪。
 *   LTE 组  绿=已注册或有数据会话，红=无 SIM / 模组故障，全灭=搜索中。
 *   WiFi 组 绿=已连接，红=已配置但断开（慢闪），全灭=无配置。
 *
 * 唯一物理按键：pm8941_pwrkey（KEY_POWER）。
 *   短按 <800ms            电量组 peek 3 秒
 *   双击（间隔 <500ms）    关机
 *   长按 2s ~ 10s          切换显示模式
 *   长按 >10.3s            PON bark（内核仅收中断，本进程不处理）
 *   长按 >12.3s            PMIC 硬件复位（不可阻止，救援通道）
 *
 * 显示模式（持久化于 /var/lib/mf601sl-ledctl/mode）：
 *   0  默认：状态灯工作；电量组灭，短按显示 3 秒
 *   1  常亮：状态灯工作；电量组常亮
 *   2  全灭：所有灯灭，仅短按后 3 秒显示
 *
 * 事件驱动：poll(2) 同时等待 evdev（电源键）、NETLINK_ROUTE（网络接口）
 * 与 NETLINK_KOBJECT_UEVENT（power_supply 变化），稳态无轮询、无周期唤醒。
 * 闪烁交给内核 LED timer trigger，用户态不设心跳。
 */

#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define ARRAY_SIZE(a)		(sizeof(a) / sizeof((a)[0]))

#define DEFAULT_LED_DIR		"/sys/class/leds"
#define DEFAULT_PSY_BAT		"/sys/class/power_supply/pm8916-bms-vm"
#define DEFAULT_NET_DIR		"/sys/class/net"
#define DEFAULT_REMOTEPROC	"/sys/class/remoteproc/remoteproc1/state"
#define DEFAULT_NM_CONN_DIR	"/etc/NetworkManager/system-connections"
#define DEFAULT_STATE_DIR	"/var/lib/mf601sl-ledctl"
#define DEFAULT_INPUT_DEV	NULL	/* NULL = 自动查找 pm8941_pwrkey */
#define DEFAULT_REG_STATE_FILE	NULL	/* NULL = 用 qmicli 实时查询 */

#define KEY_POWER		116
#define EV_KEY			1

/* 按键时序（毫秒） */
#define CLICK_MS		800
#define DOUBLE_MS		500
#define LONG_MS			2000
#define MAX_LONG_MS		10000
#define PEEK_MS			3000

/* 电量阈值：与 MF32 对齐（tools/mf32-ledctl.c） */
#define LOW_PCT			15
#define CRIT_PCT		8

/* 充电时端电压高于 OCV，查表前补偿（µV） */
#define CHARGE_COMPENSATION	80000

#define T_FAST_ON		250
#define T_FAST_OFF		250
#define T_SLOW_ON		1000
#define T_SLOW_OFF		1000

/* 实机校准的 sysfs 名（led_compose_name: "<color>:<function>"） */
#define LED_POWER_RED		"red:power"
#define LED_POWER_GREEN		"green:power"
#define LED_WAN_RED		"red:wan"
#define LED_WAN_GREEN		"green:wan"
#define LED_WLAN_RED		"red:wlan"
#define LED_WLAN_GREEN		"green:wlan"

enum led_mode {
	MODE_DEFAULT = 0,
	MODE_ALWAYS = 1,
	MODE_OFF = 2,
};

enum key_state {
	KEY_IDLE = 0,
	KEY_ARMED,
	KEY_PENDING,
	KEY_DARMED,
};

struct ocv_point {
	int uv;
	int pct;
};

/* 与 MF32 完全一致（tools/mf32-ledctl.c 的 ocv_table[] 与
 * boards/thwc-mf32/dts 的 ocv-capacity-table-0 同源）：
 * voltage-max-design 取电池真实规格 4.35V（BMS 的 OVERVOLTAGE 判定基准），
 * 充电截止另由 charger 的 qcom,fast-charge-safe-voltage=4.25V 限制。 */
static const struct ocv_point ocv_table[] = {
	{ 4350000, 100 }, { 4300000, 98 }, { 4250000, 96 }, { 4200000, 94 },
	{ 4100000, 90 }, { 4050000, 87 }, { 4000000, 84 }, { 3950000, 80 },
	{ 3900000, 75 }, { 3850000, 70 }, { 3800000, 65 }, { 3750000, 60 },
	{ 3700000, 55 }, { 3650000, 50 }, { 3600000, 45 }, { 3550000, 40 },
	{ 3500000, 35 }, { 3450000, 30 }, { 3400000, 25 }, { 3350000, 20 },
	{ 3300000, 15 }, { 3250000, 10 }, { 3200000, 5 }, { 3150000, 3 },
	{ 3100000, 1 }, { 3000000, 0 },
};

/* 运行期路径（环境变量覆盖，供注水自测；生产用默认值） */
static const char *g_led_dir = DEFAULT_LED_DIR;
static const char *g_psy_bat = DEFAULT_PSY_BAT;
static const char *g_net_dir = DEFAULT_NET_DIR;
static const char *g_remoteproc = DEFAULT_REMOTEPROC;
static const char *g_nm_conn_dir = DEFAULT_NM_CONN_DIR;
static const char *g_state_dir = DEFAULT_STATE_DIR;
static const char *g_input_dev = DEFAULT_INPUT_DEV;
static const char *g_reg_state_file = DEFAULT_REG_STATE_FILE;

struct mf601sl_state {
	enum led_mode mode;
	int bat_pct;
	bool charging;
	bool wifi_up;
	bool wifi_configured;
	bool wwan_up;
	bool modem_fault;	/* 模组故障 / 无 SIM：remoteproc 非 running 或 mmcli failed/locked */
	bool reg_denied;	/* 有卡但注册被拒：registration-denied / limited */
	long long peek_until;
	enum key_state kstate;
	long long press_ms;
	long long release_ms;
};

static volatile sig_atomic_t g_stop;

/* ---------------------------------------------------------------- 工具 */

static long long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int read_str(const char *path, char *buf, size_t len)
{
	int fd, n;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -errno;
	n = read(fd, buf, len - 1);
	close(fd);
	if (n < 0)
		return -errno;
	buf[n] = '\0';
	while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == ' '))
		buf[--n] = '\0';
	return 0;
}

static int read_int(const char *path)
{
	char buf[64];
	char *end;
	long v;

	if (read_str(path, buf, sizeof(buf)))
		return -1;
	errno = 0;
	v = strtol(buf, &end, 10);
	if (errno || end == buf)
		return -1;
	return (int)v;
}

static int write_str(const char *path, const char *val)
{
	int fd, n, ret = 0;

	fd = open(path, O_WRONLY | O_CLOEXEC);
	if (fd < 0)
		return -errno;
	n = write(fd, val, strlen(val));
	if (n < 0)
		ret = -errno;
	close(fd);
	return ret;
}

/* ---------------------------------------------------------------- LED */

static void led_path(char *buf, size_t len, const char *name,
		     const char *attr)
{
	snprintf(buf, len, "%s/%s/%s", g_led_dir, name, attr);
}

static void led_solid(const char *name)
{
	char path[160];

	led_path(path, sizeof(path), name, "trigger");
	(void)write_str(path, "none");
	led_path(path, sizeof(path), name, "brightness");
	(void)write_str(path, "1");
}

static void led_off(const char *name)
{
	char path[160];

	led_path(path, sizeof(path), name, "trigger");
	(void)write_str(path, "none");
	led_path(path, sizeof(path), name, "brightness");
	(void)write_str(path, "0");
}

static void led_blink(const char *name, int on_ms, int off_ms)
{
	char path[160], val[16];

	led_path(path, sizeof(path), name, "trigger");
	(void)write_str(path, "none");
	led_path(path, sizeof(path), name, "brightness");
	(void)write_str(path, "1");
	led_path(path, sizeof(path), name, "trigger");
	if (write_str(path, "timer")) {
		led_off(name);
		return;
	}
	snprintf(val, sizeof(val), "%d", on_ms);
	led_path(path, sizeof(path), name, "delay_on");
	(void)write_str(path, val);
	snprintf(val, sizeof(val), "%d", off_ms);
	led_path(path, sizeof(path), name, "delay_off");
	(void)write_str(path, val);
}

static void all_leds_off(void)
{
	static const char *const all[] = {
		LED_POWER_RED, LED_POWER_GREEN,
		LED_WAN_RED, LED_WAN_GREEN,
		LED_WLAN_RED, LED_WLAN_GREEN,
	};
	size_t i;

	for (i = 0; i < ARRAY_SIZE(all); i++)
		led_off(all[i]);
}

/* ---------------------------------------------------------------- 采样 */

static int voltage_to_pct(int uv, bool charging)
{
	size_t i;
	int v = uv;

	if (charging)
		v -= CHARGE_COMPENSATION;
	if (v < ocv_table[ARRAY_SIZE(ocv_table) - 1].uv)
		v = ocv_table[ARRAY_SIZE(ocv_table) - 1].uv;
	if (v > ocv_table[0].uv)
		v = ocv_table[0].uv;

	for (i = 0; i + 1 < ARRAY_SIZE(ocv_table); i++) {
		const struct ocv_point *hi = &ocv_table[i];
		const struct ocv_point *lo = &ocv_table[i + 1];
		int span, frac;

		if (v > hi->uv || v < lo->uv)
			continue;
		span = hi->uv - lo->uv;
		if (span <= 0)
			return lo->pct;
		frac = (v - lo->uv) * 100 / span;
		return lo->pct + (hi->pct - lo->pct) * frac / 100;
	}
	return 0;
}

static void sample_battery(struct mf601sl_state *st)
{
	char path[160], status[32];
	int uv;

	snprintf(path, sizeof(path), "%s/voltage_now", g_psy_bat);
	uv = read_int(path);
	snprintf(path, sizeof(path), "%s/status", g_psy_bat);
	if (read_str(path, status, sizeof(status)))
		status[0] = '\0';

	st->charging = !strcmp(status, "Charging") || !strcmp(status, "Full");
	st->bat_pct = uv >= 0 ? voltage_to_pct(uv, st->charging) : -1;
}

static bool net_is_up(const char *ifname)
{
	char path[128], buf[32];

	snprintf(path, sizeof(path), "%s/%s/operstate", g_net_dir, ifname);
	if (read_str(path, buf, sizeof(buf)))
		return false;
	return !strcmp(buf, "up");
}

static bool wifi_is_configured(void)
{
	struct dirent *de;
	DIR *dir;
	bool found = false;

	dir = opendir(g_nm_conn_dir);
	if (!dir)
		return false;
	while ((de = readdir(dir))) {
		char path[320], buf[4096];
		size_t len;

		if (de->d_name[0] == '.')
			continue;
		len = strlen(de->d_name);
		if (len < 13 || strcmp(de->d_name + len - 13, ".nmconnection"))
			continue;
		snprintf(path, sizeof(path), "%s/%s", g_nm_conn_dir, de->d_name);
		if (read_str(path, buf, sizeof(buf)))
			continue;
		if (strstr(buf, "type=wifi")) {
			found = true;
			break;
		}
	}
	closedir(dir);
	return found;
}

/*
 * 4G 模组状态分三层，不能混为一谈：
 *   1) remoteproc：Hexagon 固件是否加载（模组是否有“生命”）
 *   2) mmcli state：ModemManager 是否报 failed/locked（无 SIM、模组故障）
 *   3) 网络注册：registration-denied / limited 表示有卡但被网络拒绝
 * 只查 1)+2) 会把“注册被拒”误判成“正在搜索”，用户看到全灭而实际已经坏了。
 */
static bool modem_manager_failed(void)
{
	FILE *fp;
	char line[256];
	bool failed = false;

	fp = popen("mmcli -m 0 2>/dev/null", "r");
	if (!fp)
		return false;
	while (fgets(line, sizeof(line), fp)) {
		char *p = strstr(line, "state:");

		if (p && (strstr(p, "failed") || strstr(p, "locked"))) {
			failed = true;
			break;
		}
	}
	pclose(fp);
	return failed;
}

/* 单次 qmicli 调用里同时判定 denied / limited，避免重复 popen。
 * MF601SL_REG_STATE（自测用）非空时改读该文件，避免依赖真实 qmicli。 */
static bool modem_reg_denied(void)
{
	FILE *fp;
	char line[256];
	bool denied = false;

	if (g_reg_state_file) {
		if (read_str(g_reg_state_file, line, sizeof(line)))
			return false;
		return strcmp(line, "denied") == 0 || strcmp(line, "limited") == 0;
	}

	fp = popen("qmicli -d /dev/wwan0qmi0 --nas-get-serving-system 2>/dev/null",
		   "r");
	if (!fp)
		return false;
	while (fgets(line, sizeof(line), fp)) {
		if (strstr(line, "Registration state: 'registration-denied'") ||
		    strstr(line, "Registration state: 'registration-limited'")) {
			denied = true;
			break;
		}
	}
	pclose(fp);
	return denied;
}

static void sample_network(struct mf601sl_state *st)
{
	char buf[32];

	st->wifi_up = net_is_up("wlan0");
	st->wifi_configured = wifi_is_configured();
	st->wwan_up = net_is_up("wwan0");
	st->modem_fault = read_str(g_remoteproc, buf, sizeof(buf)) ||
			  strcmp(buf, "running") || modem_manager_failed();
	/* 模组都没起来时不必再问注册状态 */
	st->reg_denied = st->modem_fault ? false : modem_reg_denied();
}

/* ---------------------------------------------------------------- 渲染 */

/*
 * 电量组（右上）：绿=有电，红=低电。默认灭，peek 时显示。
 *   充电中：绿灯慢闪表示正在充；充满后绿灯常亮。
 *   危急低电（<=8% 且未充电）：红灯快闪，任何模式都显示（安全警示）。
 */
static void render_battery(struct mf601sl_state *st, bool visible)
{
	bool crit = st->bat_pct >= 0 && st->bat_pct <= CRIT_PCT &&
		    !st->charging;

	if (crit) {
		led_off(LED_POWER_GREEN);
		led_blink(LED_POWER_RED, T_FAST_ON, T_FAST_OFF);
		return;
	}

	if (!visible || st->bat_pct < 0) {
		led_off(LED_POWER_RED);
		led_off(LED_POWER_GREEN);
		return;
	}

	if (st->charging && st->bat_pct < 100) {
		led_off(LED_POWER_RED);
		led_blink(LED_POWER_GREEN, T_SLOW_ON, T_SLOW_OFF);
	} else if (st->bat_pct <= LOW_PCT) {
		led_off(LED_POWER_GREEN);
		led_solid(LED_POWER_RED);
	} else {
		led_off(LED_POWER_RED);
		led_solid(LED_POWER_GREEN);
	}
}

/*
 * LTE 组（左上）：
 *   红慢闪 = 模组故障 / 无 SIM（remoteproc 非 running 或 mmcli failed/locked）
 *   红常亮 = 有卡但注册被拒（registration-denied / registration-limited）
 *   绿常亮 = 数据会话已建立（wwan0 operstate=up）
 *   全灭   = 搜索中 / 未注册（真正的中间态）
 */
static void render_wan(struct mf601sl_state *st, bool visible)
{
	if (!visible) {
		led_off(LED_WAN_RED);
		led_off(LED_WAN_GREEN);
		return;
	}

	if (st->modem_fault) {
		led_off(LED_WAN_GREEN);
		led_blink(LED_WAN_RED, T_SLOW_ON, T_SLOW_OFF);
	} else if (st->wwan_up) {
		led_off(LED_WAN_RED);
		led_solid(LED_WAN_GREEN);
	} else if (st->reg_denied) {
		led_off(LED_WAN_GREEN);
		led_solid(LED_WAN_RED);
	} else {
		led_off(LED_WAN_RED);
		led_off(LED_WAN_GREEN);
	}
}

/*
 * WiFi 组（右下）：绿=已连接；红=已配置但断开（慢闪）；全灭=无配置。
 */
static void render_wlan(struct mf601sl_state *st, bool visible)
{
	if (!visible) {
		led_off(LED_WLAN_RED);
		led_off(LED_WLAN_GREEN);
		return;
	}

	if (st->wifi_up) {
		led_off(LED_WLAN_RED);
		led_solid(LED_WLAN_GREEN);
	} else if (st->wifi_configured) {
		led_off(LED_WLAN_GREEN);
		led_blink(LED_WLAN_RED, T_SLOW_ON, T_SLOW_OFF);
	} else {
		led_off(LED_WLAN_RED);
		led_off(LED_WLAN_GREEN);
	}
}

static void render(struct mf601sl_state *st)
{
	bool peek = now_ms() < st->peek_until;
	bool bat_visible;
	bool status_visible;

	switch (st->mode) {
	case MODE_ALWAYS:
		bat_visible = true;
		status_visible = true;
		break;
	case MODE_OFF:
		bat_visible = peek;
		status_visible = peek;
		break;
	case MODE_DEFAULT:
	default:
		bat_visible = peek;
		status_visible = true;
		break;
	}

	render_battery(st, bat_visible);
	render_wan(st, status_visible);
	render_wlan(st, status_visible);
}

/* ---------------------------------------------------------------- 动作 */

static void cycle_mode(struct mf601sl_state *st)
{
	char buf[8];
	char path[256];
	int fd, n;

	st->mode = (st->mode + 1) % 3;
	snprintf(buf, sizeof(buf), "%d\n", st->mode);
	snprintf(path, sizeof(path), "%s/mode", g_state_dir);
	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd >= 0) {
		n = write(fd, buf, strlen(buf));
		(void)n;
		close(fd);
	}
	/* 切模式时给一次可见反馈：六颗灯同时快闪两下 */
	led_blink(LED_POWER_RED, 150, 150);
	led_blink(LED_POWER_GREEN, 150, 150);
	led_blink(LED_WAN_RED, 150, 150);
	led_blink(LED_WAN_GREEN, 150, 150);
	led_blink(LED_WLAN_RED, 150, 150);
	led_blink(LED_WLAN_GREEN, 150, 150);
}

static void do_poweroff(void)
{
	pid_t pid;

	pid = fork();
	if (pid == 0) {
		execl("/bin/systemctl", "systemctl", "poweroff", (char *)NULL);
		_exit(127);
	}
}

static void load_mode(struct mf601sl_state *st)
{
	char path[256];
	int v;

	snprintf(path, sizeof(path), "%s/mode", g_state_dir);
	v = read_int(path);

	if (v < MODE_DEFAULT || v > MODE_OFF)
		v = MODE_DEFAULT;
	st->mode = (enum led_mode)v;
}

/* ---------------------------------------------------------------- 按键 */

struct input_event64 {
	uint64_t sec;
	uint64_t usec;
	uint16_t type;
	uint16_t code;
	int32_t value;
};

static void handle_key(struct mf601sl_state *st, int value, long long ts)
{
	long long dur;

	if (value == 2)			/* 自动重复忽略 */
		return;

	if (value == 1) {		/* 按下 */
		if (st->kstate == KEY_PENDING &&
		    ts - st->release_ms <= DOUBLE_MS) {
			st->kstate = KEY_DARMED;
		} else {
			st->kstate = KEY_ARMED;
		}
		st->press_ms = ts;
		return;
	}

	/* 松开 */
	dur = ts - st->press_ms;

	if (dur >= LONG_MS && dur <= MAX_LONG_MS) {
		/* 长按 2s~10s：切换显示模式 */
		st->kstate = KEY_IDLE;
		cycle_mode(st);
		render(st);
		return;
	}
	if (dur > MAX_LONG_MS) {
		/* 交给 PON 硬件兜底，软件不动作 */
		st->kstate = KEY_IDLE;
		return;
	}
	if (st->kstate == KEY_DARMED) {
		st->kstate = KEY_IDLE;
		do_poweroff();
		return;
	}
	if (st->kstate == KEY_ARMED && dur <= CLICK_MS) {
		st->kstate = KEY_PENDING;
		st->release_ms = ts;
		st->peek_until = now_ms() + PEEK_MS;
		render(st);
		return;
	}
	st->kstate = KEY_IDLE;
}

/* ---------------------------------------------------------------- 主循环 */

static int open_netlink_route(void)
{
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK,
				  .nl_groups = RTMGRP_LINK };
	int fd;

	fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC | SOCK_NONBLOCK,
		    NETLINK_ROUTE);
	if (fd < 0)
		return -errno;
	if (bind(fd, (struct sockaddr *)&sa, sizeof(sa))) {
		int ret = -errno;

		close(fd);
		return ret;
	}
	return fd;
}

static int open_uevent(void)
{
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK, .nl_groups = 1 };
	int fd;

	fd = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK,
		    NETLINK_KOBJECT_UEVENT);
	if (fd < 0)
		return -errno;
	if (bind(fd, (struct sockaddr *)&sa, sizeof(sa))) {
		int ret = -errno;

		close(fd);
		return ret;
	}
	return fd;
}

static int find_pwrkey_event(char *buf, size_t len)
{
	DIR *dir;
	struct dirent *de;
	bool found = false;

	dir = opendir("/sys/class/input");
	if (!dir)
		return -errno;
	while ((de = readdir(dir))) {
		char path[512], name[64];

		if (strncmp(de->d_name, "input", 5))
			continue;
		snprintf(path, sizeof(path), "/sys/class/input/%s/name",
			 de->d_name);
		if (read_str(path, name, sizeof(name)))
			continue;
		if (strcmp(name, "pm8941_pwrkey"))
			continue;
		snprintf(buf, len, "/dev/input/event%s", de->d_name + 5);
		found = true;
		break;
	}
	closedir(dir);
	return found ? 0 : -ENODEV;
}

static void handle_sig(int sig)
{
	(void)sig;
	g_stop = 1;
}

int main(void)
{
	struct mf601sl_state st = { .mode = MODE_DEFAULT, .bat_pct = -1 };
	struct sigaction sa = { .sa_handler = handle_sig };
	struct pollfd pfd[3];
	char evpath[128];
	int evfd, rtfd, uefd, ret;
	size_t i;

	if (getenv("MF601SL_LED_SYS"))
		g_led_dir = getenv("MF601SL_LED_SYS");
	if (getenv("MF601SL_PSY_BAT"))
		g_psy_bat = getenv("MF601SL_PSY_BAT");
	if (getenv("MF601SL_NET_DIR"))
		g_net_dir = getenv("MF601SL_NET_DIR");
	if (getenv("MF601SL_REMOTEPROC"))
		g_remoteproc = getenv("MF601SL_REMOTEPROC");
	if (getenv("MF601SL_NM_CONN_DIR"))
		g_nm_conn_dir = getenv("MF601SL_NM_CONN_DIR");
	if (getenv("MF601SL_STATE"))
		g_state_dir = getenv("MF601SL_STATE");
	if (getenv("MF601SL_INPUT_DEV"))
		g_input_dev = getenv("MF601SL_INPUT_DEV");
	if (getenv("MF601SL_REG_STATE"))
		g_reg_state_file = getenv("MF601SL_REG_STATE");

	if (mkdir(g_state_dir, 0755) && errno != EEXIST) {
		perror("mkdir state dir");
		return 1;
	}
	load_mode(&st);
	sample_battery(&st);
	sample_network(&st);
	all_leds_off();
	render(&st);

	if (g_input_dev) {
		snprintf(evpath, sizeof(evpath), "%s", g_input_dev);
	} else if (find_pwrkey_event(evpath, sizeof(evpath))) {
		fprintf(stderr, "mf601sl-ledctl: pwrkey not found\n");
		return 1;
	}
	evfd = open(evpath, O_RDONLY | O_CLOEXEC);
	if (evfd < 0) {
		perror("open evdev");
		return 1;
	}
	rtfd = open_netlink_route();
	uefd = open_uevent();

	sigemptyset(&sa.sa_mask);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);

	pfd[0].fd = evfd;
	pfd[0].events = POLLIN;
	pfd[1].fd = rtfd;
	pfd[1].events = POLLIN;
	pfd[2].fd = uefd;
	pfd[2].events = POLLIN;

	while (!g_stop) {
		long long now = now_ms();
		int timeout = -1;

		if (st.peek_until > now)
			timeout = (int)(st.peek_until - now);

		ret = poll(pfd, ARRAY_SIZE(pfd), timeout);
		if (ret < 0) {
			if (errno == EINTR)
				continue;
			perror("poll");
			break;
		}
		if (!ret) {		/* peek 到期 */
			render(&st);
			continue;
		}
		if (pfd[0].revents & POLLIN) {
			struct input_event64 ev;
			ssize_t n = read(evfd, &ev, sizeof(ev));

			if (n == (ssize_t)sizeof(ev) && ev.type == EV_KEY &&
			    ev.code == KEY_POWER)
				handle_key(&st, ev.value,
					   (long long)ev.sec * 1000 +
					   ev.usec / 1000);
		}
		if (pfd[1].revents & POLLIN) {
			char buf[8192];

			while (read(rtfd, buf, sizeof(buf)) > 0)
				;
			sample_network(&st);
			render(&st);
		}
		if (pfd[2].revents & POLLIN) {
			char buf[8192];

			while (read(uefd, buf, sizeof(buf)) > 0)
				;
			sample_battery(&st);
			render(&st);
		}
	}

	for (i = 0; i < ARRAY_SIZE(pfd); i++)
		if (pfd[i].fd >= 0)
			close(pfd[i].fd);
	all_leds_off();
	return 0;
}
