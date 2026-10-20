# Fleury's four packages staged side by side, then reused.
# From the repository root: FLEURY=../fleury vhs tool/demo/stage.tape
Output tool/demo/stage.gif
Source tool/demo/common.tape
Set Height 800

Hide
Type `export PS1='$ ' PROMPT_COMMAND= && cd "$(tool/demo/setup.sh fleury)" && clear`
Enter
Wait
Show

Type "rk stage    # build and check all four packages; publish nothing"
Sleep 500ms
Enter
Wait
Sleep 2500ms
Type "rk stage    # nothing changed, so nothing is rebuilt"
Sleep 500ms
Enter
Wait
Sleep 5s
