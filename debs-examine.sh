#!/bin/bash
usage="$(basename "$0") [-h] [-d DISTRO] [-r RELEASE] [-p dpkg-l_file ] [-k keys_file] [-l sources.list]
Examine filelists of deb-package(s) for given distribution release,
where:
    -h  show this help text
    -d  distro name (debian, ubuntu)
    -r  release name (buster, focal)
    -p  path to full dpkg-l_file
    -k  path to file with keys for apt-key (separated by newlines)
    -l  path to sources.list file
"

while getopts ":hd:r:p:k:l:" opt; do
  case "$opt" in
    h) echo "$usage"; exit;;
    d) distro=$OPTARG;;
    r) release=$OPTARG;;
    p) dpkg_l_file=$OPTARG;;
    k) apt_keys_file=$OPTARG;;
    l) sources_list_file=$OPTARG;;
    \?) echo "Error: Unimplemented option chosen!"; echo "$usage" >&2; exit 1;;
  esac
done

# mandatory arguments
if [ ! "$distro" ] || [ ! "$release" ] || [ ! "$dpkg_l_file" ] ; then
  echo "Error: arguments -d, -r and -p must be provided!"
  echo "$usage" >&2; exit 1
fi

cpu_arch=$(arch)
if [ "$cpu_arch" != "i686" ] && [ "$cpu_arch" != "x86_64" ] ; then
  echo "Error: currently only i686 and x86_64 CPU architectures are supported!";
  exit 2;
fi

# commands which are dynamically generated from optional arguments
no_install_suggests="--no-install-suggests";
gpg_pkg="gpg";

# distros and their versions
supported_ubuntu_releases="trusty|xenial|bionic|focal|jammy|lunar|mantic|noble|devel";
eol_ubuntu_releases="precise|quantal|raring|saucy|utopic|vivid|wily|yakkety|zesty|artful|cosmic|disco|eoan|groovy|hirsute|impish|kinetic";
ubuntu_release_is_eol=0;

supported_debian_releases="oldoldstable|buster|oldstable|bullseye|stable|bookworm";
testing_debian_releases="testing|trixie";
rolling_debian_releases="sid|unstable|experimental";
eol_debian_releases="squeeze|wheezy|jessie|stretch";
debian_release_is_eol=0;

# main code

if [ "$distro" != "debian" ] && [ "$distro" != "ubuntu" ]; then
    echo "Error: only Debian and Ubuntu are supported!";
    exit 1;
else
    if [ "$distro" == "ubuntu" ]; then
       ubuntu_releases="$supported_ubuntu_releases|$eol_ubuntu_releases"
       if ! echo "$release" | grep -wEq "$ubuntu_releases"
       then
            echo "Error: Ubuntu $release is not supported!";
            echo "Supported Ubuntu releases are ${ubuntu_releases//|/, }.";
            exit 1;
       else
           if echo "$release" | grep -wEq "$eol_ubuntu_releases"
           then
                echo "Warning: Ubuntu $release is EOL, but script will continue to run.";
                ubuntu_release_is_eol=1;
           fi
       fi
    fi

    if [ "$distro" == "debian" ]; then
       debian_releases="$supported_debian_releases|$eol_debian_releases|$testing_debian_releases|$rolling_debian_releases"
       if ! echo "$release" | grep -wEq "$debian_releases"
       then
            echo "Error: Debian $release is not supported!";
            echo "Supported Debian releases are ${debian_releases//|/, }.";
            exit 1;
       else
           if echo "$release" | grep -wEq "$eol_debian_releases"
           then
                echo "Warning: Debian $release is EOL, but script will continue run.";
                debian_release_is_eol=1;

                # workaround for Debain Squeeze - it does not have `--no-install-suggests` 
                # and has problem with GPG signature
                if [[ "$release" == "squeeze" || "$release" == "jessie" ]]; then
                    no_install_suggests="--force-yes";
                fi
           fi
       fi
    fi
fi

# prepare Dockerfile
if [ "$distro" == "ubuntu" ] || [ "$distro" == "debian" ]; then
    echo "FROM $distro:$release" > Dockerfile
fi

cat << EOF >> Dockerfile
RUN [ -z "$http_proxy" ] && echo "Using direct network connection" || echo 'Acquire::http::Proxy "$http_proxy";' > /etc/apt/apt.conf.d/99proxy
EOF

# operate
if [[ "$distro" == "debian" || "$distro" == "ubuntu" ]]; then
    # fix sources for EOL version
    if [ $debian_release_is_eol == 1 ]; then
        echo "RUN echo 'deb http://archive.debian.org/debian $release main contrib non-free' > /etc/apt/sources.list" >> Dockerfile
        echo "RUN echo 'deb http://archive.debian.org/debian-security $release/updates main contrib non-free' >> /etc/apt/sources.list" >> Dockerfile
    fi
    if [ $ubuntu_release_is_eol == 1 ]; then
        echo "RUN echo 'deb http://old-releases.ubuntu.com/ubuntu $release main universe multiverse restricted' > /etc/apt/sources.list
RUN echo 'deb http://old-releases.ubuntu.com/ubuntu $release-updates main universe multiverse restricted' >> /etc/apt/sources.list
RUN echo 'deb http://old-releases.ubuntu.com/ubuntu $release-security main universe multiverse restricted' >> /etc/apt/sources.list" >> Dockerfile
    fi

    # add 32-bit packages
    if [ "$cpu_arch" == "x86_64" ]; then
        echo "RUN dpkg --add-architecture i386" >> Dockerfile
    fi

    # update default package cache
    echo "RUN apt-get update" >> Dockerfile
    echo "RUN apt-get install -y --no-install-recommends $no_install_suggests apt-transport-https" >> Dockerfile 

    # add relevant keys (if any)
    if [ "$apt_keys_file" ]; then
        [ "$release" == "xenial" ] && gpg_pkg="" 
        echo "RUN apt-get install -y --no-install-recommends $no_install_suggests software-properties-common gnupg $gpg_pkg dirmngr ca-certificates" >> Dockerfile

    while IFS= read -r key
        do
          [ -n "$key" ] &&  echo "RUN apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com '$key' || true" >> Dockerfile
        done < "$apt_keys_file"             
    fi

    # replace sources.list with our file
    [ -n "$sources_list_file" ] && echo "COPY '$sources_list_file' /etc/apt/sources.list" >> Dockerfile

    # update package cache for our sources.list file
    {
    echo "RUN apt-get update"

    # install and update apt-file for enabled repositories
    echo "RUN apt-get install -y apt-file gawk"
    echo "RUN apt-file update" 
    } >> Dockerfile
    
    # copy dpkg-l file to the container
    [ -n "$dpkg_l_file" ] && echo "COPY '$dpkg_l_file' /tmp/dpkg-l" >> Dockerfile
fi

# prepare storage folder
rm -rf out
mkdir -p out
cd out || { echo "Error: can't cd to out directory!"; exit 3; }

# prepare download script
cat << \EOF > script.sh
#!/bin/bash
set -e
#set -x

mkdir -p /tmp/out
cd /tmp/out

echo "We have a list with $(wc -l /tmp/dpkg-l | awk '{print $1}') packages, let's parse it."

grep ^ii /tmp/dpkg-l | awk '$3 !~ /bpo[0-9]{1,2}/' | awk '{print $2}' > dpkg-l_all_packages
grep -Ev ":i386$|:amd64$" dpkg-l_all_packages > dpkg-l_defarch_packages
grep -E ":i386$" dpkg-l_all_packages > dpkg-l_i386_packages || true
grep -E ":amd64$" dpkg-l_all_packages > dpkg-l_amd64_packages || true

grep ^ii /tmp/dpkg-l | awk '$3 ~ /bpo[0-9]{1,2}/' | awk '{print $2}' > dpkg-l_all_packages_bpo || true
grep -Ev ":i386$|:amd64$" dpkg-l_all_packages_bpo > dpkg-l_defarch_packages_bpo || true
grep -E ":i386$" dpkg-l_all_packages_bpo > dpkg-l_i386_packages_bpo || true
grep -E ":amd64$" dpkg-l_all_packages_bpo > dpkg-l_amd64_packages_bpo || true

# default CPU arch
if [ -s "dpkg-l_defarch_packages" ];
then
    echo -n "Getting filelist for default CPU-arch packages: "
    apt-file list -F -f < dpkg-l_defarch_packages > filelist_defarch
    [ -s "filelist_defarch" ] && echo "got $(wc -l filelist_defarch | awk '{print $1}') file(s)."
fi

if [ -s "dpkg-l_defarch_packages_bpo" ];
then
    echo -n "Getting filelist for default CPU-arch packages from backports: "
    apt-file list -F -f < dpkg-l_defarch_packages_bpo --filter-suites "$(lsb_release -cs)-backports" > filelist_defarch_bpo
    [ -s "filelist_defarch_bpo" ] && echo "got $(wc -l filelist_defarch_bpo | awk '{print $1}') file(s)."
fi

# 32-bit i386 CPU arch
if [ -s "dpkg-l_i386_packages" ];
then
    echo -n "Getting filelist for 32-bit i386 CPU-arch packages: "
    sed 's/:i386$//g' dpkg-l_i386_packages | apt-file list -F -f - --architecture i386 > filelist_i386
    [ -s "filelist_i386" ] && echo "got $(wc -l filelist_i386 | awk '{print $1}') file(s)."
fi

if [ -s "dpkg-l_i386_packages_bpo" ];
then
    echo -n "Getting filelist for 32-bit i386 CPU-arch packages from backports: "
    sed 's/:i386$//g' dpkg-l_i386_packages_bpo | apt-file list -F -f - --filter-suites "$(lsb_release -cs)-backports" --architecture i386 > filelist_i386_bpo
    [ -s "filelist_i386_bpo" ] && echo "got $(wc -l filelist_i386_bpo | awk '{print $1}') file(s)."
fi

# 64-bit amd64 CPU arch
if [ -s "dpkg-l_amd64_packages" ];
then
    echo -n "Getting filelist for 64-bit amd64 CPU-arch packages: "
    sed 's/:amd64$//g' dpkg-l_amd64_packages | apt-file list -F -f - --architecture amd64 > filelist_amd64
    [ -s "filelist_amd64" ] && echo "got $(wc -l filelist_amd64 | awk '{print $1}') file(s)."
fi

if [ -s "dpkg-l_amd64_packages_bpo" ];
then
    echo -n "Getting filelist for 64-bit amd64 CPU-arch packages from backports: "
    sed 's/:amd64$//g' dpkg-l_amd64_packages_bpo | apt-file list -F -f - --filter-suites "$(lsb_release -cs)-backports" --architecture amd64 > filelist_amd64_bpo
    [ -s "filelist_amd64_bpo" ] && echo "got $(wc -l filelist_amd64_bpo | awk '{print $1}') file(s)."
fi

find /tmp/out -type f -empty -delete
#chown -R "$(id --user):$(id --group)" /root/
EOF

# build container
docker build .. -t "pe-$distro-$release"

# run script inside container
docker run --rm -v "${PWD}":/tmp/out -u "$(id -u):$(id -g)" -it "pe-$distro-$release" bash /tmp/out/script.sh

