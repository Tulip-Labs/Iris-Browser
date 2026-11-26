#!/usr/bin/env python3
# Odin's fmt reads { and } in a format string as a placeholder ({{ and }}
# are literal braces). Iris builds page scripts with fmt.tprintf, so an
# unescaped brace turns a script into "%!(MISSING CLOSE BRACE)" and the
# page throws a SyntaxError. This fails when any format string has one.
import re,sys,glob
# fmt.<x>printf[ln](  — format is first string arg; for sbprintf/bprintf/fprintf/wprintf it's the second
pat=re.compile(r'fmt\.(t|a|s|c|e|)printf(ln)?\(|fmt\.(sb|b|f|w)printf(ln)?\(')
def read_str(s,i):
    # s[i] is quote char; returns (literal, end)
    q=s[i]; j=i+1
    if q=='`':
        k=s.index('`',j); return s[j:k],k+1
    out=[]
    while s[j]!='"':
        if s[j]=='\\': out.append(s[j:j+2]); j+=2
        else: out.append(s[j]); j+=1
    return ''.join(out),j+1
hits=[]
for f in sorted(glob.glob('linux/src/**/*.odin',recursive=True)):
    s=open(f).read()
    for m in pat.finditer(s):
        i=m.end()
        second = m.group(3) is not None
        if second:
            # skip first arg up to top-level comma
            depth=0
            while True:
                c=s[i]
                if c in '([': depth+=1
                elif c in ')]': depth-=1
                elif c==',' and depth==0: i+=1; break
                i+=1
        while s[i] in ' \t\n': i+=1
        if s[i] not in '"`': continue
        lit,end=read_str(s,i)
        if '{' in lit or '}' in lit:
            # already escaped?
            bad = re.sub(r'\{\{|\}\}','',lit)
            if '{' in bad or '}' in bad:
                hits.append((f,s.count('\n',0,i)+1,lit[:70].replace('\n',' ')))
for h in hits: print(*h,sep=' | ')
print(len(hits), "format strings with an unescaped brace", file=sys.stderr)
sys.exit(1 if hits else 0)
