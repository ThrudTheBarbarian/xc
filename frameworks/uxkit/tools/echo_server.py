# echo_server.py — a TCP echo peer for the socket gate: prints the port it listens on, echoes each line
# back after a short pause (so a read before the reply finds nothing), and closes on "bye".  An extra
# argument listens on IPv6 instead.  It exits by itself after a minute, so it never outlives its gate.
import socket,sys,threading,os
threading.Timer(60, lambda: os._exit(0)).start()
s=socket.socket(socket.AF_INET6 if len(sys.argv)>2 else socket.AF_INET); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('localhost' if len(sys.argv)<=2 else '::1',0)); s.listen(4); print(s.getsockname()[1],flush=True)
def serve(c):
    import time; time.sleep(0.3)
    while True:
        d=c.recv(4096)
        if not d or d.startswith(b'bye'): break
        c.sendall(d)
    c.close()
while True:
    c,_=s.accept(); threading.Thread(target=serve,args=(c,),daemon=True).start()
