# NightlyScript
A script for downloading via rsync the nightly builds from (typically) Stockholm, via rsync.
 
The script provides for downloading either the most recent or the last successful nightly build for any of the 
available Orc releases, both TS and GW.
 
The script accepts a number of command-line options (see Usage) and will also read from a config file which
is sourced from either $CWD/orc-nightly-config or /etc/orc-nightly-config. If no command-line options are 
provided and there is no config file found, the script will fall back to hard-coded fail-safe parameters.
 
In addition to the config file, the script will read ./orc-nightly-exclude or /etc/orc-nightly-exclude from
which a list of filename patterns to exclude from the synchronization will be read. The file accepts both
full and partial pathnames and will perform variable expansion and globbing on the patterns when determining
which files/directories to exclude.
 
The script utilizes SSH to connect to the source. rsync then tunnels vi the SSH connection. If a username is
specified on the command-line or via the config file, the script will locate all SSH keys in the nominated
user's $HOME/.ssh/ directory and will use these when attempting to make the SSH connection. If no valid keys
are found, and if the server permits it, the user will be prompted for a password with which to log in.
 
The script requires a directory structure on the destination which mimics that found on the Stockholm servers i.e.
 
/pub/builds/nightly/GW/latest/release/orc --soft linked-> /orcreleases/GW/
 
If the destination path does not exist the script will prompt the user to either proceed (and create the required path) or to abort.

Usage: `$(basename $0) [-a][-c][-d][-o][-h <host>][-l][-p][-q][-r <build>][-s][-t][-w]`
 
Supported options are:

    -a        Download all builds (as set in /etc/orc-nightly.conf or as defined as default values in this script
    -b        Exclude PDF's e.g. manuals
    -c        Exclude client applications e.g. Orc Trader & Sauron
    -d        Delete files which do not exist on the server but exist on the client system
    -h        Help
    -l        Download the latest available nightly build (mutually exclusive with -u)
    -p        Use non-standard port for connecting to source
    -q        Be quiet - don't output progress info
    -r        Which build to download - requires an argument - the desired build e.g. TS-9
    -s        Download source - requires an argument - the host to download from
    -t        Include the Trade Monitor client app (excluded by default)
    -u        Download the last successful nightly build (mutually exclusive with -l)
    -w        Exclude windows components e.g. exes and dlls
    -x        Override default source paths for builds e.g. /orcreleases
