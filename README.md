# debs-examine

Shell script for getting file lists for deb-package(s) which are going to be installed

Under the hood this script uses Docker to obtain minimal file-system of needed system release and run `apt-file list` for provided input data. The created Docker images will be named with `de-` prefix, you can remove them manually later.

Usage scenario is the following: one has a computer with set of installed deb-packages, saved the list of them by running `dpkg -l`, saved a list of the repositories and now one wants to selectively install this set of packages basing on their contents.

Steps to use:

```
# get list of packages
dpkg -l > dpkg-l_pc

# get list of repositories
grep ^deb -r /etc/apt --include=*.list --no-filename | sort -u > sources.list_pc

# get list of keys
apt-key list | grep ^pub -A1 | grep "^ " | tr -d ' ' > keys_pc
apt-key list | grep ^pub | awk -F/ '{print $2}' | awk '{print $1}' >> keys_pc
```

The one should copy all three files *dpkg-l_pc*, *sources.list_pc* and *keys_pc* into *in/* directory and run the script:


```
./debs-examine.sh -d debian -r bullseye -p in/dpkg-l_pc -k in/keys_pc -l in/sources.list_pc
```

where

* `-d` (distribution, mandatory) - `debian` for Debian, `ubuntu` for Ubuntu;
* `-r` (release, mandatory) - all versions starting from Debian 6 (`squeeze`), Ubuntu 12.04 LTS (`precise`) are supported by script;
* `-p` (mandatory) - path to full `dpkg -l` file;
* `-k` (optional) - path to file with keys for apt-key (separated by newlines);
* `-l` (optional) - path to *sources.list* file.

The resulting filelists will be saved in the *out/* directory:

* filelists for various repositories (*filelist_defarch*, *filelist_amd64*, *filelist_i386*);
* filelists for backports repositories (*filelist_amd64_bpo*, *filelist_defarch_bpo*, *filelist_i386_bpo*).

These filelists may be grep'ed in any way to suite user needs. And finally one will be able to install only needed deb-packages into the target system.
