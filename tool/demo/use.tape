# rk use switching the rk command between this checkout and a release, in a
# sandbox: launchers go to a throwaway XDG_DATA_HOME, not your own.
# From the repository root: vhs tool/demo/use.tape
Output tool/demo/use.gif
Source tool/demo/common.tape
Set Width 860
Set Height 330

Hide
Type `export SHELL=/bin/bash PS1='$ ' PROMPT_COMMAND= XDG_DATA_HOME="$(mktemp -d)" && export PATH="$XDG_DATA_HOME/rk/bin:$PATH" && cd "$(tool/demo/setup.sh use)" && clear`
Enter
Wait
Show

Type "rk use"
Sleep 400ms
Enter
Sleep 5s
Escape
Wait
Sleep 800ms
Type "rk use local     # run this checkout's build as rk"
Sleep 400ms
Enter
Wait
Sleep 1500ms
Type "rk use github    # back to the latest release"
Sleep 400ms
Enter
Wait
Sleep 5s
