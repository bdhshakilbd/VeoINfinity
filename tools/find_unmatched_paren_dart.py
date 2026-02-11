path = r"c:\Users\Lenovo\Music\veo3_another\lib\screens\video_mastering_screen.dart"
with open(path,'r',encoding='utf-8') as f:
    s = f.read()

in_single=False
in_double=False
escape=False
cum=0
last_open_idx=None
i=0
N=len(s)
while i<N:
    ch=s[i]
    if escape:
        escape=False
        i+=1
        continue
    if ch=='\\':
        escape=True
        i+=1
        continue
    # interpolation start
    if in_single or in_double:
        if ch=='\$' and i+1<N and s[i+1]=='{':
            # enter interpolation
            i+=2
            brace_depth=1
            # parse interpolation content respecting nested braces and strings
            interp_in_single=False
            interp_in_double=False
            interp_escape=False
            while i<N and brace_depth>0:
                c=s[i]
                if interp_escape:
                    interp_escape=False
                    i+=1
                    continue
                if c=='\\':
                    interp_escape=True
                    i+=1
                    continue
                if not interp_in_double and c=="'":
                    interp_in_single = not interp_in_single
                    i+=1
                    continue
                if not interp_in_single and c=='"':
                    interp_in_double = not interp_in_double
                    i+=1
                    continue
                if not interp_in_single and not interp_in_double:
                    if c=='{':
                        brace_depth+=1
                    elif c=='}':
                        brace_depth-=1
                # count parentheses inside interpolation
                if not interp_in_single and not interp_in_double:
                    if c=='(': 
                        cum+=1; last_open_idx=i
                    elif c==')':
                        if cum>0: cum-=1
                        else:
                            print('Unmatched ) at',i)
                            raise SystemExit(1)
                i+=1
            continue
        # otherwise normal char inside string: skip
        if ch=="'" and not in_double:
            in_single=False
            i+=1
            continue
        if ch=='"' and not in_single:
            in_double=False
            i+=1
            continue
        i+=1
        continue
    # not in string
    if ch=="'":
        in_single=True; i+=1; continue
    if ch=='"':
        in_double=True; i+=1; continue
    if ch=='(':
        cum+=1; last_open_idx=i
    elif ch==')':
        if cum>0: cum-=1
        else:
            print('Unmatched ) at index',i)
            raise SystemExit(1)
    i+=1

if cum>0:
    idx=last_open_idx
    line = s.count('\n',0,idx)+1
    col = idx - s.rfind('\n',0,idx)
    print('Unmatched ( at index',idx,'line',line,'col',col)
    start=max(0,idx-200)
    end=min(len(s),idx+200)
    print('\n---context---')
    print(s[start:end])
else:
    print('No unmatched parentheses found')
