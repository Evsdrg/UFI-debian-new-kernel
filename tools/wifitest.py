import socket, sys, time
host = sys.argv[1]; port = int(sys.argv[2]); mib = int(sys.argv[3])
s = socket.create_connection((host, port), 5)
s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 262144)
buf = b'x' * 262144
n = 0; t = time.time()
while n < mib * 1024 * 1024:
    s.sendall(buf); n += len(buf)
el = time.time() - t
s.close()
print('%.1f' % (mib * 8 / el))
