import re
import subprocess
ROOT_FILENAME = 'throwback'

f_p8 = open(ROOT_FILENAME + '.p8', 'r+', newline='\n')
lua = open(ROOT_FILENAME + '.lua', 'r', newline='\n').read()
p8 = f_p8.read()

new_p8 = re.sub(r'__lua__\n.*\n__gfx__', '__lua__\n{}\n__gfx__'.format(lua), p8, flags=re.DOTALL)

f_p8.seek(0)
f_p8.write(new_p8)
f_p8.truncate()
f_p8.close()

# subprocess.run(['C:\Program Files (x86)\PICO-8\pico8.exe', '-run', ROOT_FILENAME + '.p8'])
