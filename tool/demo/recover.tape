# A stage interrupted partway, then finished by running it again.
# From the repository root: FLEURY=../fleury vhs tool/demo/recover.tape
Output tool/demo/recover.gif
Source tool/demo/common.tape
Set Height 800

Hide
Type `export PS1='$ ' PROMPT_COMMAND= && cd "$(tool/demo/setup.sh fleury)" && clear`
Enter
Wait
Show

Type "rk stage"
Sleep 500ms
Enter
Sleep 6500ms
Ctrl+C
Wait
Sleep 1500ms
Type "rk stage    # run it again: it keeps what finished"
Sleep 500ms
Enter
Wait
Sleep 5s
