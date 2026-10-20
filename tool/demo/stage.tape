# Fleury's four packages staged side by side: interrupted, resumed, reused.
# From the repository root: FLEURY=../fleury vhs tool/demo/stage.tape
Output tool/demo/stage.gif
Source tool/demo/common.tape
Set Width 860
Set Height 500

Hide
Type `export PS1='$ ' PROMPT_COMMAND= && cd "$(tool/demo/setup.sh fleury)" && clear`
Enter
Wait
Show

Type "rk stage"
Sleep 400ms
Enter
Sleep 7500ms
Ctrl+C
Wait
Sleep 1200ms
Type "rk stage    # again: it keeps what finished"
Sleep 400ms
Enter
Wait
Sleep 2000ms
Type "rk stage    # and again: nothing to rebuild"
Sleep 400ms
Enter
Wait
Sleep 5s
