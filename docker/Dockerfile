FROM ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai
ENV FORCE_UNSAFE_CONFIGURE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    ack asciidoc autoconf automake autopoint binutils bison build-essential \
    bzip2 ccache ca-certificates clang cmake cpio curl device-tree-compiler \
    fakeroot flex gawk gcc-multilib g++-multilib gettext genisoimage git gperf \
    gnutls-dev haveged help2man intltool jq libc6-dev-i386 libelf-dev \
    libglib2.0-dev libgmp3-dev libltdl-dev libmpc-dev libmpfr-dev libncurses-dev \
    libpython3-dev libreadline-dev libssl-dev libtool libyaml-dev \
    llvm lrzsz msmtp ninja-build nodejs npm patch pkgconf \
    python3 python3-cryptography python3-docutils python3-pip python3-ply \
    python3-pyelftools python3-requests qemu-utils quilt re2c rsync scons \
    sharutils squashfs-tools subversion swig texinfo uglifyjs unzip vim \
    wget xmlto xxd zlib1g-dev zstd \
    && rm -rf /var/lib/apt/lists/*

RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

WORKDIR /workdir

CMD ["/bin/bash"]
