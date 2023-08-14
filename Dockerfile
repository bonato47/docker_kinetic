ARG ROS_DISTRO=kinetic
FROM ros:kinetic  as core-build-dependencies
ENV DEBIAN_FRONTEND=noninteractive

# install core compilation and access dependencies for building the libraries
RUN apt-get update && apt-get install -y \
    autoconf \
    automake \
    build-essential \
    cmake \
    curl \
    g++ \
    gcc \
    git \
    gnupg2 \
    libtool \
    lsb-release \
    make \
    pkg-config \
    wget \
    bash-completion \
    silversearcher-ag \
    apt-transport-https \
    less \
    alsa-utils \
    ros-${ROS_DISTRO}-ros-control \
    ros-${ROS_DISTRO}-ros-controllers \
    libeigen3-dev \
    ros-${ROS_DISTRO}-vrpn-client-ros \
    && sudo apt-get upgrade -y && sudo apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Tell docker we want to use bash instead of sh in general
SHELL ["/bin/bash", "-c"]

FROM core-build-dependencies as google-dependencies

RUN apt-get update && apt-get install -y \
    libgtest-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# install gtest
WORKDIR /tmp
RUN mkdir gtest_build && cd gtest_build && cmake /usr/src/gtest && make -j \
    && cp lib/* /usr/local/lib || cp *.a /usr/local/lib

RUN rm -rf /tmp/* && ldconfig


FROM core-build-dependencies as robot-model-dependencies

RUN apt-get update && apt-get install -y \
    libboost-all-dev \
    liburdfdom-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp
ARG EIGEN_TAG=3.4.0
RUN wget -c https://gitlab.com/libeigen/eigen/-/archive/${EIGEN_TAG}/eigen-${EIGEN_TAG}.tar.gz -O - | tar -xz \
    && cd eigen-${EIGEN_TAG} && mkdir build && cd build && env CXXFLAGS=-DEIGEN_MPL2_ONLY cmake .. && make install \
    && cd ../.. && rm -r eigen-${EIGEN_TAG} || exit 1

ARG OSQP_TAG=0.6.2
RUN git clone --depth 1 -b v${OSQP_TAG} --recursive https://github.com/oxfordcontrol/osqp \
    && cd osqp && mkdir build && cd build && cmake -G "Unix Makefiles" .. && cmake --build . --target install \
    && cd ../.. && rm -r osqp || exit 1

ARG OSQP_EIGEN_TAG=0.6.4
RUN git clone --depth 1 -b v${OSQP_EIGEN_TAG} https://github.com/robotology/osqp-eigen.git \
    && cd osqp-eigen && mkdir build && cd build && cmake .. && make -j && make install \
    && cd ../.. && rm -r osqp-eigen || exit 1

ARG PINOCCHIO_TAG=2.6.9
RUN git clone --depth 1 -b v${PINOCCHIO_TAG} --recursive https://github.com/stack-of-tasks/pinocchio \
    && cd pinocchio && mkdir build && cd build \
    && cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_PYTHON_INTERFACE=OFF \
    -DBUILD_TESTING=OFF && make -j $(nproc --ignore=1) && make install && cd ../.. && rm -r pinocchio || exit 1

RUN ldconfig


FROM robot-model-dependencies as development-dependencies
RUN apt-get update && apt-get install -y \
    clang \
    gdb \
    python3 \
    python3-dev \
    python3-pip \
    tar \
    unzip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# install python requirements
RUN pip3 install numpy setuptools pybind11

# install google dependencies
COPY --from=google-dependencies /usr/include/gtest /usr/include/gtest
COPY --from=google-dependencies /usr/local/lib/libgtest* /usr/local/lib/


FROM development-dependencies as proto-dependencies-20.04
COPY --from=ghcr.io/epfl-lasa/control-libraries/proto-dependencies:20.04 /usr/local/include/google /usr/local/include/google
COPY --from=ghcr.io/epfl-lasa/control-libraries/proto-dependencies:20.04 /usr/local/lib/libproto* /usr/local/lib/
COPY --from=ghcr.io/epfl-lasa/control-libraries/proto-dependencies:20.04 /usr/local/bin/protoc /usr/local/bin
RUN ldconfig


FROM development-dependencies as proto-dependencies-22.04
COPY --from=ghcr.io/epfl-lasa/control-libraries/proto-dependencies:22.04 /usr/local/include/google /usr/local/include/google
COPY --from=ghcr.io/epfl-lasa/control-libraries/proto-dependencies:22.04 /usr/local/lib/libproto* /usr/local/lib/
COPY --from=ghcr.io/epfl-lasa/control-libraries/proto-dependencies:22.04 /usr/local/bin/protoc /usr/local/bin
RUN ldconfig


FROM development-dependencies as proto-dependencies-latest
COPY --from=ghcr.io/epfl-lasa/control-libraries/proto-dependencies:latest /usr/local/include/google /usr/local/include/google
COPY --from=ghcr.io/epfl-lasa/control-libraries/proto-dependencies:latest /usr/local/lib/libproto* /usr/local/lib/
COPY --from=ghcr.io/epfl-lasa/control-libraries/proto-dependencies:latest /usr/local/bin/protoc /usr/local/bin
RUN ldconfig


FROM ros:kinetic as license-information
RUN mkdir -p /usr/share/doc/control-libraries
COPY ./licenses /usr/share/doc/control-libraries/licenses


FROM license-information as ssh-configuration

RUN apt-get update && apt-get install -y \
    sudo \
    libssl-dev \
    ssh \
    iputils-ping \
    rsync \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Configure sshd server settings
RUN ( \
    echo 'LogLevel DEBUG2'; \
    echo 'PubkeyAuthentication yes'; \
    echo 'Subsystem sftp /usr/lib/openssh/sftp-server'; \
  ) > /etc/ssh/sshd_config_development \
  && mkdir /run/sshd

ENV USER ros
ENV HOME /home/${USER}


# create and configure a new user
ARG UID=1000
ARG GID=1000
RUN addgroup --gid ${GID} ${USER}
RUN adduser --gecos "Remote User" --uid ${UID} --gid ${GID} ${USER} && yes | passwd ${USER}
RUN usermod -a -G dialout ${USER}
RUN echo "${USER} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99_aptget
RUN chmod 0440 /etc/sudoers.d/99_aptget && chown root:root /etc/sudoers.d/99_aptget

# Configure sshd entrypoint to authorise the new user for ssh access and
# optionally update UID and GID when invoking the container with the entrypoint script
COPY ./docker/sshd_entrypoint.sh /sshd_entrypoint.sh
RUN chmod 744 /sshd_entrypoint.sh

# create the credentials to be able to pull private repos using ssh
RUN mkdir /root/.ssh/ && ssh-keyscan github.com | tee -a /root/.ssh/known_hosts

RUN echo "session required pam_limits.so" | tee --append /etc/pam.d/common-session > /dev/null


#install rospackage from github
WORKDIR /home/${USER}/ros_ws/src

RUN git clone https://github.com/RLoad/iiwa_toolkit.git
RUN git clone https://github.com/RLoad/net-ft-ros.git
RUN git clone https://github.com/nbfigueroa/lpvDS-lib.git
RUN git clone https://github.com/epfl-lasa/gaussian-process-regression.git
RUN git clone https://github.com/epfl-lasa/mathlib.git
RUN git clone https://github.com/epfl-lasa/fast-gmm.git

# Give bashrc back to user
WORKDIR /home/${USER}
RUN sudo chown -R ${USER}:${HOST_GID} .bashrc

# Add cmake option to bash rc if needed
RUN if [ "${USE_SIMD}" = "ON" ] ; \
    then echo "export ENABLE_SIMD=ON" >> /home/${USER}/.bashrc ; fi

SHELL ["/bin/bash", "-c"]
### Build ros workspace
USER ${USER}
WORKDIR /home/${USER}/ros_ws
RUN sudo apt update
RUN sudo apt install -y libeigen3-dev
RUN rosdep update
RUN source /home/${USER}/.bashrc && rosdep install --from-paths src --ignore-src -r -y
RUN source /home/${USER}/.bashrc && catkin_make;

