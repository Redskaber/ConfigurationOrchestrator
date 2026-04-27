# Home Manager Options

home.file
Attribute set of files to link into the user home.
Type: attribute set of (submodule)
Default:
{ }
Declared by:
<home-manager/modules/files.nix>

home.file.<name>.enable
Whether this file should be generated. This option allows specific files to be disabled.
Type: boolean
Default:
true
Declared by:
<home-manager/modules/files.nix>

home.file.<name>.executable
Set the execute bit. If null, defaults to the mode of the source file or to false for files created through the text option.
Type: null or boolean
Default:
null
Declared by:
<home-manager/modules/files.nix>

home.file.<name>.force
Whether the target path should be unconditionally replaced by the managed file source. Warning, this will silently delete the target regardless of whether it is a file or link.
Type: boolean
Default:
false
Declared by:
<home-manager/modules/files.nix>

home.file.<name>.ignorelinks
When recursive is enabled, adds -ignorelinks flag to lndir
It causes lndir to not treat symbolic links in the source directory specially. The link created in the target directory will point back to the corresponding (symbolic link) file in the source directory. If the link is to a directory
Type: boolean
Default:
false
Declared by:
<home-manager/modules/files.nix>

home.file.<name>.onChange
Shell commands to run when file has changed between generations. The script will be run after the new files have been linked into place.
Note, this code is always run when recursive is enabled.
Type: strings concatenated with “\n”
Default:
""
Declared by:
<home-manager/modules/files.nix>

home.file.<name>.recursive
If the file source is a directory, then this option determines whether the directory should be recursively linked to the target location. This option has no effect if the source is a file.
If false (the default) then the target will be a symbolic link to the source directory. If true then the target will be a directory structure matching the source’s but whose leaves are symbolic links to the files of the source directory.
Type: boolean
Default:
false
Declared by:
<home-manager/modules/files.nix>

home.file.<name>.source
Path of the source file or directory. If home.file.<name>.text is non-null then this option will automatically point to a file containing that text.
Type: absolute path
Declared by:
<home-manager/modules/files.nix>

home.file.<name>.target
Path to target file relative to HOME.
Type: non-empty string
Default:
name
Declared by:
<home-manager/modules/files.nix>

home.file.<name>.text
Text of the file. If this option is null then home.file.<name>.source must be set.
Type: null or strings concatenated with “\n”
Default:
null
Declared by:
<home-manager/modules/files.nix>

---

xdg.configFile
Attribute set of files to link into the user’s XDG configuration home.
Type: attribute set of (submodule)
Default:
{ }
Declared by:
<home-manager/modules/misc/xdg.nix>

xdg.configFile.<name>.enable
Whether this file should be generated. This option allows specific files to be disabled.
Type: boolean
Default:
true
Declared by:
<home-manager/modules/misc/xdg.nix>

xdg.configFile.<name>.executable
Set the execute bit. If null, defaults to the mode of the source file or to false for files created through the text option.
Type: null or boolean
Default:
null
Declared by:
<home-manager/modules/misc/xdg.nix>

xdg.configFile.<name>.force
Whether the target path should be unconditionally replaced by the managed file source. Warning, this will silently delete the target regardless of whether it is a file or link.
Type: boolean
Default:
false
Declared by:
<home-manager/modules/misc/xdg.nix>

xdg.configFile.<name>.ignorelinks
When recursive is enabled, adds -ignorelinks flag to lndir
It causes lndir to not treat symbolic links in the source directory specially. The link created in the target directory will point back to the corresponding (symbolic link) file in the source directory. If the link is to a directory
Type: boolean
Default:
false
Declared by:
<home-manager/modules/misc/xdg.nix>

xdg.configFile.<name>.onChange
Shell commands to run when file has changed between generations. The script will be run after the new files have been linked into place.
Note, this code is always run when recursive is enabled.
Type: strings concatenated with “\n”
Default:
""
Declared by:
<home-manager/modules/misc/xdg.nix>

xdg.configFile.<name>.recursive
If the file source is a directory, then this option determines whether the directory should be recursively linked to the target location. This option has no effect if the source is a file.
If false (the default) then the target will be a symbolic link to the source directory. If true then the target will be a directory structure matching the source’s but whose leaves are symbolic links to the files of the source directory.
Type: boolean
Default:
false
Declared by:
<home-manager/modules/misc/xdg.nix>

xdg.configFile.<name>.source
Path of the source file or directory. If xdg.configFile.<name>.text is non-null then this option will automatically point to a file containing that text.
Type: absolute path
Declared by:
<home-manager/modules/misc/xdg.nix>

xdg.configFile.<name>.target
Path to target file relative to xdg.configHome.
Type: non-empty string
Default:
name
Declared by:
<home-manager/modules/misc/xdg.nix>

xdg.configFile.<name>.text
Text of the file. If this option is null then xdg.configFile.<name>.source must be set.
Type: null or strings concatenated with “\n”
Default:
null
Declared by:
<home-manager/modules/misc/xdg.nix>
