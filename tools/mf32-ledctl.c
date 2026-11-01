// SPDX-License-Identifier: GPL-2.0-only
/*
 * mf32-ledctl.c — MF32 状态灯、电量条与电源键守护进程
 *
 * 事件驱动：poll(2) 同时等待 evdev（电源键）、NETLINK_ROUTE（网络接口
 * 事件）与 NETLINK_KOBJECT_UEVENT（power_supply 变化），稳态无轮询、
 * 无周期性唤醒。闪烁交给内核 LED timer trigger，用户态不设心跳。
 *
 * 唯一物理按键：pm8941_pwrkey（KEY_POWER）。
 *   短按 <800ms            电量条 peek 3 秒
 *   双击（间隔 <500ms）    关机
 *   长按 2s ~ 10s          切换 LED 显示模式
 *   长按 >10.3s            PON bark（内核仅收到中断，本进程不处理）
 *   长按 >12.3s            PMIC 硬件复位（不可阻止，救援通道）
 *
 * 显示模式（持久化于 /var/lib/mf32-ledctl/mode）：
 *   0  默认：状态灯常工作；电量条默认灭，短按显示 3 秒
 *   1  常亮：状态灯常工作；电量条常亮
 *   2  全灭：所有 LED 灭，仅短按后 3 秒显示
 */

#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <poll.h>
#include <sys/socket.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
#define DEFAULT_STATE_DIR	"/var/lib/mf32-ledctl"
#define DEFAULT_INPUT_DEV	NULL	/* NULL = 自动查找 pm8941_pwrkey */

#define KEY_POWER		116
#define EV_KEY			1

/* 按键时序（毫秒） */
#define CLICK_MS		800
#define DOUBLE_MS		500
#define LONG_MS			2000
#define MAX_LONG_MS		10000
#define PEEK_MS			3000

/* 电量条阈值 */
#define LOW_PCT			15
#define CRIT_PCT		8
#define STEP_HYST		3

/* 充电时端电压高于 OCV，查表前补偿（µV） */
#define CHARGE_COMPENSATION	80000

#define T_FAST_ON		250
#define T_FAST_OFF		250
#define T_SLOW_ON		1000
#define T_SLOW_OFF		1000
#define T_FILL_ON		500
#define T_FILL_OFF		500

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

/* 与 DTS 的 ocv-capacity-table-0 保持一致（boards/thwc-mf32/dts） */
static const struct ocv_point ocv_table[] = {
	{ 4350000, 100 }, { 4300000, 98 }, { 4250000, 96 }, { 4200000, 94 },
	{ 4100000, 90 }, { 4050000, 87 }, { 4000000, 84 }, { 3950000, 80 },
	{ 3900000, 75 }, { 3850000, 70 }, { 3800000, 65 }, { 3750000, 60 },
	{ 3700000, 55 }, { 3650000, 50 }, { 3600000, 45 }, { 3550000, 40 },
	{ 3500000, 35 }, { 3450000, 30 }, { 3400000, 25 }, { 3350000, 20 },
	{ 3300000, 15 }, { 3250000, 10 }, { 3200000, 5 }, { 3150000, 3 },
	{ 3100000, 1 }, { 3000000, 0 },
};

/* 实机校准（2026-10-30）：只列有灯珠的 LED，物理顺序低→高 */
static const char *const bat_leds[] = { "bat1", "batl2", "batl3", "batl4" };
static const char *const status_leds[] = { "4g_1", "4g_type", "wifistatus" };

/* 运行期路径（环境变量覆盖，供注水自测；生产用默认值） */
static const char *g_led_dir = DEFAULT_LED_DIR;
static const char *g_psy_bat = DEFAULT_PSY_BAT;
static const char *g_net_dir = DEFAULT_NET_DIR;
static const char *g_remoteproc = DEFAULT_REMOTEPROC;
static const char *g_nm_conn_dir = DEFAULT_NM_CONN_DIR;
static const char *g_state_dir = DEFAULT_STATE_DIR;
static const char *g_input_dev = DEFAULT_INPUT_DEV;

struct mf32_state {
	enum led_mode mode;
	int bat_pct;
	bool charging;
	bool wifi_up;
	bool wifi_configured;
	bool wwan_up;
	bool modem_fault;
	long long peek_until;
	enum key_state kstate;
	long long press_ms;
	long long release_ms;
	int bar_level;			/* 带滞回的电量条档位 1..4 */
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

	fd = open(path, O_RDONLY);
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

	fd = open(path, O_WRONLY);
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
	write_str(path, "none");
	led_path(path, sizeof(path), name, "brightness");
	write_str(path, "1");
}

static void led_off(const char *name)
{
	char path[160];

	led_path(path, sizeof(path), name, "trigger");
	write_str(path, "none");
	led_path(path, sizeof(path), name, "brightness");
	write_str(path, "0");
}

static void led_blink(const char *name, int on_ms, int off_ms)
{
	char path[160], val[16];

	led_path(path, sizeof(path), name, "trigger");
	write_str(path, "none");
	led_path(path, sizeof(path), name, "brightness");
	write_str(path, "1");
	led_path(path, sizeof(path), name, "trigger");
	if (write_str(path, "timer")) {
		led_off(name);
		return;
	}
	snprintf(val, sizeof(val), "%d", on_ms);
	led_path(path, sizeof(path), name, "delay_on");
	write_str(path, val);
	snprintf(val, sizeof(val), "%d", off_ms);
	led_path(path, sizeof(path), name, "delay_off");
	write_str(path, val);
}

static void all_leds_off(void)
{
	size_t i;

	for (i = 0; i < ARRAY_SIZE(status_leds); i++)
		led_off(status_leds[i]);
	for (i = 0; i < ARRAY_SIZE(bat_leds); i++)
		led_off(bat_leds[i]);
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

static void sample_battery(struct mf32_state *st)
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
 * 4G 模组状态：remoteproc 只反映 Hexagon 固件是否加载，不反映 SIM/注册状态。
 * ModemManager 的 "state: failed / failed reason: sim-missing" 才是用户可见的
 * 故障态（无 SIM 卡是这台设备最常见的状态）。用 mmcli 查询，只在 netlink
 * 事件触发时调用，不参与轮询。
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

static void sample_network(struct mf32_state *st)
{
	char buf[32];

	st->wifi_up = net_is_up("wlan0");
	st->wifi_configured = wifi_is_configured();
	st->wwan_up = net_is_up("wwan0");
	st->modem_fault = read_str(g_remoteproc, buf, sizeof(buf)) ||
			  strcmp(buf, "running") || modem_manager_failed();
}

/* ---------------------------------------------------------------- 渲染 */

/*
 * 电量条档位（带 3% 降档滞回）：
 *   >75% 4 档，>50% 3 档，>25% 2 档，其余 1 档。
 */
static int bar_level(struct mf32_state *st)
{
	int lvl = 1;
	int prev = st->bar_level;

	if (st->bat_pct > 75)
		lvl = 4;
	else if (st->bat_pct > 50)
		lvl = 3;
	else if (st->bat_pct > 25)
		lvl = 2;

	if (prev > lvl && st->bat_pct >= (prev - 1) * 25 - STEP_HYST)
		lvl = prev;
	st->bar_level = lvl;
	return lvl;
}

static void render_status_leds(struct mf32_state *st, bool visible)
{
	if (!visible) {
		led_off("4g_1");
		led_off("4g_type");
		led_off("wifistatus");
		return;
	}

	/* 4G：模组故障 > 数据会话 > 空闲 */
	if (st->modem_fault) {
		led_solid("4g_type");
		led_off("4g_1");
	} else if (st->wwan_up) {
		led_off("4g_type");
		led_solid("4g_1");
	} else {
		led_off("4g_type");
		led_off("4g_1");
	}

	/* WiFi：已连接常亮；已配置未连接慢闪；无配置灭 */
	if (st->wifi_up)
		led_solid("wifistatus");
	else if (st->wifi_configured)
		led_blink("wifistatus", T_SLOW_ON, T_SLOW_OFF);
	else
		led_off("wifistatus");
}

static void render_battery_bar(struct mf32_state *st, bool visible)
{
	bool crit = st->bat_pct >= 0 && st->bat_pct <= CRIT_PCT &&
		    !st->charging;
	int lvl, i;

	/* 危急低电在任意模式下都常驻快闪，属安全警示 */
	if (crit) {
		for (i = 0; i < (int)ARRAY_SIZE(bat_leds); i++)
			led_off(bat_leds[i]);
		led_blink(bat_leds[0], T_FAST_ON, T_FAST_OFF);
		return;
	}

	if (!visible || st->bat_pct < 0) {
		for (i = 0; i < (int)ARRAY_SIZE(bat_leds); i++)
			led_off(bat_leds[i]);
		return;
	}

	lvl = bar_level(st);
	for (i = 0; i < (int)ARRAY_SIZE(bat_leds); i++) {
		if (i < lvl) {
			led_solid(bat_leds[i]);
		} else if (st->charging && i == lvl && st->bat_pct < 100) {
			led_blink(bat_leds[i], T_FILL_ON, T_FILL_OFF);
		} else {
			led_off(bat_leds[i]);
		}
	}
}

static void render(struct mf32_state *st)
{
	bool peek = now_ms() < st->peek_until;
	bool bar_visible;

	switch (st->mode) {
	case MODE_ALWAYS:
		bar_visible = true;
		break;
	case MODE_OFF:
		bar_visible = peek;
		break;
	case MODE_DEFAULT:
	default:
		bar_visible = peek;
		break;
	}

	/* 全灭模式下状态灯也只能由 peek 唤起 */
	render_status_leds(st, st->mode != MODE_OFF || peek);
	render_battery_bar(st, bar_visible);
}

/* ---------------------------------------------------------------- 动作 */

static void cycle_mode(struct mf32_state *st)
{
	char buf[8];
	int fd, n;

	char path[256];

	st->mode = (st->mode + 1) % 3;
	snprintf(buf, sizeof(buf), "%d\n", st->mode);
	snprintf(path, sizeof(path), "%s/mode", g_state_dir);
	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd >= 0) {
		n = write(fd, buf, strlen(buf));
		(void)n;
		close(fd);
	}
	/* 切模式时给一次可见反馈：四颗电量条同时闪两下 */
	{
		int i;

		for (i = 0; i < (int)ARRAY_SIZE(bat_leds); i++)
			led_blink(bat_leds[i], 150, 150);
	}
	st->bar_level = 0;
}

static void do_poweroff(void)
{
	pid_t pid;

	pid = fork();
	if (pid == 0) {
		execl("/bin/systemctl", "systemctl", "poweroff", NULL);
		_exit(127);
	}
}

static void load_mode(struct mf32_state *st)
{
	char path[256];
	int v;

	snprintf(path, sizeof(path), "%s/mode", g_state_dir);
	v = read_int(path);

	if (v < MODE_DEFAULT || v > MODE_OFF)
		v = MODE_DEFAULT;
	st->mode = v;
}

/* ---------------------------------------------------------------- 按键 */

struct input_event64 {
	uint64_t sec;
	uint64_t usec;
	uint16_t type;
	uint16_t code;
	int32_t value;
};

static void handle_key(struct mf32_state *st, int value, long long ts)
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
		close(fd);
		return -errno;
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
		close(fd);
		return -errno;
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
	struct mf32_state st = { .mode = MODE_DEFAULT, .bat_pct = -1 };
	struct sigaction sa = { .sa_handler = handle_sig };
	struct pollfd pfd[3];
	char evpath[128];
	int evfd, rtfd, uefd, ret, i;

	if (getenv("MF32_LED_SYS"))
		g_led_dir = getenv("MF32_LED_SYS");
	if (getenv("MF32_PSY_BAT"))
		g_psy_bat = getenv("MF32_PSY_BAT");
	if (getenv("MF32_NET_DIR"))
		g_net_dir = getenv("MF32_NET_DIR");
	if (getenv("MF32_REMOTEPROC"))
		g_remoteproc = getenv("MF32_REMOTEPROC");
	if (getenv("MF32_NM_CONN_DIR"))
		g_nm_conn_dir = getenv("MF32_NM_CONN_DIR");
	if (getenv("MF32_STATE"))
		g_state_dir = getenv("MF32_STATE");
	if (getenv("MF32_INPUT_DEV"))
		g_input_dev = getenv("MF32_INPUT_DEV");

	mkdir(g_state_dir, 0755);
	load_mode(&st);
	sample_battery(&st);
	sample_network(&st);
	all_leds_off();
	render(&st);

	if (g_input_dev) {
		snprintf(evpath, sizeof(evpath), "%s", g_input_dev);
	} else if (find_pwrkey_event(evpath, sizeof(evpath))) {
		fprintf(stderr, "mf32-ledctl: pwrkey not found\n");
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
		if (getenv("MF32_DEBUG") && ret > 0)
			fprintf(stderr, "poll: ev=%d rt=%d ue=%d timeout=%d\n",
				pfd[0].revents, pfd[1].revents,
				pfd[2].revents, timeout);
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

			if (getenv("MF32_DEBUG"))
				fprintf(stderr, "ev read n=%zd type=%u code=%u val=%d\n",
					n, ev.type, ev.code, ev.value);
			if (n == sizeof(ev)) {
				if (ev.type == EV_KEY && ev.code == KEY_POWER) {
					handle_key(&st, ev.value,
						   ev.sec * 1000 +
						   ev.usec / 1000);
				}
			}
		}
		if (pfd[1].revents & POLLIN) {
			char buf[8192];

			/* 非阻塞：排空到 EAGAIN */
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

	for (i = 0; i < (int)ARRAY_SIZE(pfd); i++)
		if (pfd[i].fd >= 0)
			close(pfd[i].fd);
	all_leds_off();
	return 0;
}
