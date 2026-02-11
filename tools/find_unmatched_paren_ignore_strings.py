path = r"c:\Users\Lenovo\Music\veo3_another\lib\screens\video_mastering_screen.dart"
with open(path,'r',encoding='utf-8') as f:
    s = f.read()

in_single=False
in_double=False
escape=False
cum=0
for i,ch in enumerate(s):
    if escape:
        escape=False
        continue
    if ch=='\\':
        escape=True
        continue
    # Handle entering/exiting strings (simple, doesn't handle raw r'')
    if not in_double and ch=="'":
        in_single = not in_single
        continue
    if not in_single and ch=='"':
        in_double = not in_double
        continue
    if in_single or in_double:
        continue
    if ch=='(':
        cum+=1
        last_open_idx=i
    elif ch==')':
        if cum>0:
            cum-=1
        else:
            print('Unmatched ) at index',i)
            break

if cum>0:
    # find last unmatched '('
    idx = last_open_idx
    # compute line/col
    line = s.count('\n',0,idx)+1
    col = idx - s.rfind('\n',0,idx)
    print('Unmatched ( at index',idx,'line',line,'col',col)
    start=max(0,idx-200)
    end=min(len(s),idx+200)
    print('\n---context---')
    print(s[start:end])
else:
    print('No unmatched parentheses found')
