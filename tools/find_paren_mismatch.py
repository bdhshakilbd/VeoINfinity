import sys
path = r"c:\Users\Lenovo\Music\veo3_another\lib\screens\video_mastering_screen.dart"
with open(path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

cum = 0
maxv = 0
maxline = 0
for i,l in enumerate(lines):
    opens = l.count('(')
    closes = l.count(')')
    cum += (opens - closes)
    if cum > maxv:
        maxv = cum
        maxline = i+1

print(f'final cumulative={cum}, max={maxv} at line {maxline}')
start = max(0, maxline-4)
end = min(len(lines), maxline+3)
print('--- context ---')
for i in range(start, end):
    print(f'{i+1}: {lines[i].rstrip()}')

# also try to find last unmatched '(' by scanning backwards: find position of n'th '(' where n=cumulative
if cum > 0:
    needed = cum
    count = 0
    for i, l in enumerate(lines):
        for j, ch in enumerate(l):
            if ch == '(':
                count += 1
                if count == needed:
                    print('\nLikely unmatched ( at line', i+1, 'char', j+1)
                    # print surrounding
                    s = max(0, i-3)
                    e = min(len(lines), i+3)
                    for k in range(s,e):
                        print(f'{k+1}: {lines[k].rstrip()}')
                    sys.exit(0)
    print('Could not locate exact unmatched (')
else:
    print('No unmatched opens')
