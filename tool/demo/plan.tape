# rk plan for the README's two packages, cli depending on core.
# From the repository root: vhs tool/demo/plan.tape
Output tool/demo/plan.gif
Source tool/demo/common.tape
Set Width 640
Set Height 600

Hide
Type `export PS1='$ ' PROMPT_COMMAND= && cd "$(tool/demo/setup.sh example)" && clear`
Enter
Wait
Show

Type "rk plan"
Sleep 400ms
Enter
Wait
Sleep 8s
