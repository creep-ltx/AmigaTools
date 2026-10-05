import sys,re,bisect,collections
S=sys.argv[1]; base=int(sys.argv[2],16); fn=sys.argv[3]; n=int(sys.argv[4])
fa=None
for l in open(S+'/syms.txt'):
    p=l.split()
    if len(p)==3 and p[2]==fn: fa=int(p[0],16)
labs=[]; fl=None; pend=[]
for l in open(S+'/pg.lst',errors='ignore'):
    ma=re.match(r'00:([0-9A-F]{8})\s',l)
    ml=re.search(r'\d+:\s*([.\w]+):',l)
    if ml: pend.append(ml.group(1))
    if ma:
        a=int(ma.group(1),16)
        for nm in pend:
            if nm==fn: fl=a
            labs.append((a,nm))
        pend=[]
labs.sort(); la=[a for a,_ in labs]
cnt=collections.Counter(); seen=False
for l in open(S+'/trace.txt',errors='ignore'):
    if 'BLOB' in l: seen=True; continue
    if not seen: continue
    m=re.search(r'N/A\s+([0-9a-f]{6})\s',l)
    if not m: continue
    off=int(m.group(1),16)-base-fa+fl
    i=bisect.bisect_right(la,off)-1
    if i>=0 and off>=fl and off<fl+3000: cnt[labs[i][1]]+=1
for k,v in sorted(cnt.items(),key=lambda x:-x[1])[:30]: print(f'{k:12s} {v/n:7.0f}')
