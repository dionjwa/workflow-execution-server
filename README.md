# API/CLI for execution of workflows.

Currently supports CWL but is built to be agnostic.


## Developer setup

	[Install haxe](https://haxe.org/download/)

In the project directory:

	npm install

	haxelib newrepo
	haxelib install --always etc/haxe/server-build.hxml
	cp etc/haxe/server-build.hxml build.hxml
	haxe build.hxml

If you are running Sublime Text with the Haxe plugin, the build shortcut should see the `build.hxml` file and build.
