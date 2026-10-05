import sys,re,bisect,collections
S=sys.argv[1]; base=int(sys.argv[2],16); size=int(sys.argv[3]); n=int(sys.argv[4])
syms=[]
for l in open(S+'/syms.txt'):
    p=l.split()
    if len(p)==3 and p[1] in 'tT': syms.append((int(p[0],16),p[2]))
syms.sort(); addrs=[a for a,_ in syms]
cnt=collections.Counter(); seen=False; tot=0
for l in open(S+'/trace.txt',errors='ignore'):
    if 'BLOB' in l: seen=True; continue
    if not seen: continue
    m=re.search(r'N/A\s+([0-9a-f]{6})\s',l)
    if not m: continue
    pc=int(m.group(1),16)-base
    if 0<=pc<size:
        i=bisect.bisect_right(addrs,pc)-1
        cnt[syms[i][1] if i>=0 else '?']+=1; tot+=1
for k,v in cnt.most_common(25): print(f'{k:24s} {v/n:8.0f} per line')
print('total engine', tot/n, 'per line')
