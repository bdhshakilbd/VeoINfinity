path = r"c:\Users\Lenovo\Music\veo3_another\lib\screens\video_mastering_screen.dart"
with open(path, 'r', encoding='utf-8') as f:
    s = f.read()

# Traverse backwards
close_count = 0
for idx in range(len(s)-1, -1, -1):
    ch = s[idx]
    if ch == ')':
        close_count += 1
    elif ch == '(':
        if close_count == 0:
            # found unmatched '('
            # find line and column
            prefix = s[:idx]
            line = prefix.count('\n') + 1
            col = idx - prefix.rfind('\n')
            print('Unmatched ( at index', idx, 'line', line, 'col', col)
            # print surrounding
            start = max(0, idx-200)
            end = min(len(s), idx+200)
            print('\n---context---')
            context = s[start:end]
            print(context)
            break
        else:
            close_count -= 1
else:
    print('No unmatched opening parenthesis found')
