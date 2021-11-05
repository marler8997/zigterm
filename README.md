
# terminfo stuff

The `zigterm.terminfo` file contains the zigterm capabilities in "terminfo" format.  Note that there is also an older "termcap" format, maybe i'll deal with that later.

Use the `tic` program to install this file.

```sh
tic zigterm.terminfo
```

After you install it, you can verify the installation with:

```sh
infocmp zigterm
```

# Shell Logger for Debug

Maybe I should create a shell logger that can log all the input/output and forward it to the real shell.  This could be done by setting `SHELL=shelllogger` then setting the real shell to something like `SHELL_LOGGER_SHELL=the-real-shell`.
