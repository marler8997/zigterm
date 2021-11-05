
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
