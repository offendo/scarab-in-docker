FROM ubuntu:20.04

# default a user name
ARG user=nilay

# user id and group id, helpful to make these same as your host ones
ARG uid=1000
ARG gid=1001

# copy this to an environment variable https://blog.bitsrc.io/how-to-pass-environment-info-during-docker-builds-1f7c5566dd0e
ENV USER=${user}
ENV UID=${uid}
ENV GID=${gid}

EXPOSE 2022
EXPOSE 7676
EXPOSE 7677
EXPOSE 8265
EXPOSE 6007

# Remove any third-party apt sources to avoid issues with expiring keys and install some basic
# utilities and python-dev
RUN rm -f /etc/apt/sources.list.d/*.list \
  && apt-get update && apt-get install -y \
  curl \
  zsh \
  ca-certificates \
  sudo \
  git \
  bzip2 \
  wget \
  libx11-6 \
  python-dev \
  && rm -rf /var/lib/apt/lists/*

# Create a working directory
RUN mkdir /soe
WORKDIR /soe

# Create a non-root user and switch to it
RUN echo "User: ${USER}" \
  && groupadd -g ${GID} -o ${USER} \
  && useradd -u ${UID} -g ${GID} ${USER} && echo "${USER}:${USER}" | chpasswd \
  && mkdir -p /home/${USER} && chown -R ${USER}:${USER} /home/${USER}

# Adding the openssh-server
ENV TZ=America/Los_Angeles
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone && \
  apt-get update && apt-get install -y openssh-server vim

# Setting up a non-privileged ssh directory for sshd
# see https://www.golinuxcloud.com/run-sshd-as-non-root-user-without-sudo
RUN mkdir -p /opt/ssh
RUN ssh-keygen -q -N "" -t dsa -f /opt/ssh/ssh_host_dsa_key \
  &&  ssh-keygen -q -N "" -t rsa -b 4096 -f /opt/ssh/ssh_host_rsa_key \
  &&  ssh-keygen -q -N "" -t ecdsa -f /opt/ssh/ssh_host_ecdsa_key \
  &&  ssh-keygen -q -N "" -t ed25519 -f /opt/ssh/ssh_host_ed25519_key

# Note the custom config defined here, which uses a non-privileged port,
# rejects pass word auth, etc. See details in link above
COPY sshd_config /opt/ssh/sshd_config

# Set up a service for the user to be able to run. Modify on the fly to add env user we created
COPY sshd-1.service /etc/systemd/sshd-1.service
RUN sed -i 's/<PUT_USER_HERE>/$USER/' /etc/systemd/sshd-1.service \
  && cat /etc/systemd/sshd-1.service

# Modify permissions to each folder so user can run
RUN chmod 600 /opt/ssh/* \
  &&  chmod 644 /opt/ssh/sshd_config \
  &&  chown ${USER}:${USER} /etc/systemd/sshd-1.service \
  &&  chown -R ${USER}:${USER} /opt/ssh/

# IMPORTANT: modified config prohibits password auth, preventing brute force
RUN mkdir -p /home/${USER}/.ssh
COPY id_rsa.pub /home/${USER}/.ssh/authorized_keys

# All users can use /home/${USER} as their home directory
ENV HOME=/home/${USER}
RUN mkdir $HOME/.cache $HOME/.config \
  && chmod -R 755 $HOME

# update permissions for .ssh to be more restrictive
RUN chmod -R 700 /home/${USER}/.ssh \
  && chmod 644 /home/${USER}/.ssh/authorized_keys

# Default powerline10k theme, no plugins installed
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v1.1.2/zsh-in-docker.sh)"

# Set shell to zsh
RUN chsh -s /usr/bin/zsh ${USER}

# Copy my ssh config. Useful (for me) in pulling files onto container and attached volumes
# from resources I have access to.
COPY ssh_config /home/${USER}/.ssh/config

# Warning! It is generally not advised to trust public keys without checking them yourself. This allows me clone
# git with ssh on container/job launch without having to accept a fingerprint check (file contains ssh public keys
# for github.com). Check these for yourself or remove this step. More detail here: https://serverfault.com/a/701637
COPY ssh_known_hosts /home/${USER}/.ssh/known_hosts

# Need to set user as owner of their home directory, now that we've populated things
RUN chown -R ${USER}:${USER} /home/${USER} && chmod -R 755 /home/${USER}

# Finally, add the user to sudoers. In some sense this undoes any security added by running sshd as a non-privileged user
RUN sudo usermod -aG sudo ${USER} && passwd -d ${USER}

USER $USER
WORKDIR /home/${USER}

# change shells to the one we want to use (probably not needed, but verifying it works)
SHELL ["/usr/bin/zsh", "-c"]

# These can speed up builds that include conda/pip install (like below)
ENV PIP_CACHE_DIR .cache/buildkit/pip
RUN mkdir -p $HOME/$PIP_CACHE_DIR

# sone final setup: add this lint to the top of each shell file to turn off output in interactive modes
# this is required for SFTP to work
RUN echo "[[ "$-" != *i* ]] && return" > .bashrc \
  && sed -i '1s/^/[[ "$-" != *i* ]] \&\& return\n/' .zshrc


# Actual Scarab Setup:
# installs gcc, g++, make, etc.
RUN sudo apt install build-essential -y \
  libconfig++-dev \
  zlib1g-dev \
  libsnappy-dev \
  libpthread-stubs0-dev \
  clang cmake python3 python3-pip zip

ENV PATH=/usr/lib/python3/dist-packages:$PATH
RUN sudo pip3 install gdown \
  && gdown 19flaVdjO9xpzdRPFXZUUECdT4Br7gzHa \
  && unzip pinplay-drdebug-3.5-pin-3.5-97503-gac534ca30-gcc-linux-20230412T030035Z-001.zip

ENV PIN_ROOT=/home/${USER}/pinplay-drdebug-3.5-pin-3.5-97503-gac534ca30-gcc-linux
ENV SCARAB_ENABLE_MEMTRACE=1

RUN git clone --recurse-submodules https://github.com/hpsresearchgroup/scarab.git \
  && pip3 install -r scarab/bin/requirements.txt \
  && cd scarab/src && make

# RUN sudo python scarab/utils/qsort/scarab_test_qsort.py test_out
CMD ["/usr/sbin/sshd","-D", "-f", "/opt/ssh/sshd_config",  "-E", "/tmp/sshd.log"]
