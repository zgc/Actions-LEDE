FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai
ENV FORCE_UNSAFE_CONFIGURE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ccache clang cmake cpio curl device-tree-compiler \
    flex gawk gcc-multilib g++-multilib gettext git libelf-dev \
    libglib2.0-dev libncurses5-dev libncursesw5-dev libssl-dev \
    libtool llvm ninja-build patch pkgconf python3 python3-pyelftools \
    rsync squashfs-tools subversion swig unzip wget xxd zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

WORKDIR /workdir

CMD ["/bin/bash"]
