#!/bin/sh

# Script to deploy eduvpn on a CentOS >= 7 installation.
#
# Tested on CentOS 7.2
#
# NOTE: make sure you installed all updates:
#     $ sudo yum clean all && sudo yum -y update
#
# NOTE: make sure the HOSTNAME used below can be resolved, either in DNS
#       or with a /etc/hosts entry, e.g.:
#
#           10.20.30.44 vpn.example
#
# NOTE: edit the variables below if you need to. Set the correct HOSTNAME and
#       the interface connecting to the Internet from your machine
#
# NOTE: please configure your network with NetworkManager! NetworkManager 
#       and its cli tool will be installed below and enabled
#
# TODO:
# - make this script work on Fedora out of the box, not just CentOS

###############################################################################
# VARIABLES
###############################################################################

# VARIABLES
HOSTNAME=vpn.example
EXTERNAL_IF=eth0

###############################################################################
# SYSTEM
###############################################################################

# https://lobste.rs/c/4lfcnm (danielrheath)
set -e # stop the script on errors
set -u # unset variables are an error
set -o pipefail # piping a failed process into a successful one is an arror

###############################################################################
# LOGGING
###############################################################################

# CentOS forwards to syslog, but we want to use journald, enable persistent
# storage, but only for 31 days
sed -i 's/^#Storage=auto/Storage=persistent/' /etc/systemd/journald.conf
sed -i 's/^#MaxRetentionSec=/MaxRetentionSec=2678400/' /etc/systemd/journald.conf
systemctl restart systemd-journald

###############################################################################
# SOFTWARE
###############################################################################

# remove firewalld, does not yet do what we need (missing IPv6 NAT capability)
yum -y remove firewalld

# enable EPEL
yum -y install epel-release

# enable COPR repos
curl -L -o /etc/yum.repos.d/fkooman-eduvpn-dev-epel-7.repo https://copr.fedorainfracloud.org/coprs/fkooman/eduvpn-dev/repo/epel-7/fkooman-eduvpn-dev-epel-7.repo

# install NetworkManager, if not yet installed
yum -y install NetworkManager

# install software (dependencies)
yum -y install openvpn php-opcache openssl telnet \
    policycoreutils-python iptables iptables-services patch \
    iptables-services php-cli psmisc net-tools pwgen

# install software (VPN packages)
yum -y install vpn-server-api

###############################################################################
# SELINUX
###############################################################################

# allow OpenVPN to listen on its management ports, and some additional VPN
# ports for load balancing
semanage port -a -t openvpn_port_t -p udp 1195-1201    # allow up to 8 instances
semanage port -a -t openvpn_port_t -p tcp 11940-11947  # allow up to 8 instances

# install a custom module to allow reading/writing to OpenVPN/httpd paths
checkmodule -M -m -o resources/vpn-management.mod resources/vpn-management.te
semodule_package -o resources/vpn-management.pp -m resources/vpn-management.mod
semodule -i resources/vpn-management.pp

###############################################################################
# PHP
###############################################################################

cp resources/99-eduvpn.ini /etc/php.d/99-eduvpn.ini

###############################################################################
# VPN-SERVER-API
###############################################################################

mkdir /etc/vpn-server-api/${HOSTNAME}
cp /usr/share/doc/vpn-server-api-*/config.yaml.example /etc/vpn-server-api/${HOSTNAME}/config.yaml
chown apache.openvpn /etc/vpn-server-api/${HOSTNAME}/config.yaml
chmod 0440 /etc/vpn-server-api/${HOSTNAME}/config.yaml

# OTP log for two-factor auth
sudo -u apache vpn-server-api-init --instance ${HOSTNAME}

###############################################################################
# OPENVPN
###############################################################################

# enable forwarding
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf

# forwarding disables accepting RAs on our external interface, so we have to
# explicitly enable it here to make IPv6 work. This is only needed for deploys
# with native IPv6 obtained via router advertisements, not for fixed IPv6
# configurations
echo "net.ipv6.conf.${EXTERNAL_IF}.accept_ra = 2" >> /etc/sysctl.conf
sysctl -p

###############################################################################
# DAEMONS
###############################################################################

systemctl enable NetworkManager
# https://www.freedesktop.org/wiki/Software/systemd/NetworkTarget/
# we need this for sniproxy and openvpn to start only when the network is up
# because we bind to other addresses than 0.0.0.0 and ::
systemctl enable NetworkManager-wait-online

# start services
systemctl restart NetworkManager
systemctl restart NetworkManager-wait-online

# VMware tools, does nothing when not running on VMware
yum -y install open-vm-tools
systemctl enable vmtoolsd
systemctl restart vmtoolsd

###############################################################################
# OPENVPN SERVER CONFIG
###############################################################################

# generate the server configuration files
#vpn-server-api-server-config --instance ${HOSTNAME} --pool internet --generate --cn ${HOSTNAME}

# enable and start OpenVPN
#systemctl enable openvpn@server-${HOSTNAME}-internet-{0,1,2,3}
#systemctl start openvpn@server-${HOSTNAME}-internet-{0,1,2,3}

###############################################################################
# FIREWALL
###############################################################################

## generate and install the firewall
#vpn-server-api-generate-firewall --install

#systemctl enable iptables
#systemctl enable ip6tables

## flush existing firewall rules if they exist and activate the new ones
#systemctl restart iptables
#systemctl restart ip6tables

###############################################################################
# POST INSTALL
###############################################################################

# Secure OpenSSH
sed -i "s/^#PermitRootLogin yes/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config 
# Override the algorithms and ciphers. By default CentOS 7 is not really secure
# See also: https://discovery.cryptosense.com
echo "" >> /etc/ssh/sshd_config # first newline, because default file does not end with new line
echo "KexAlgorithms curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256,diffie-hellman-group14-sha1" >> /etc/ssh/sshd_config
echo "Ciphers chacha20-poly1305@openssh.com,aes128-ctr,aes192-ctr,aes256-ctr,aes128-gcm@openssh.com,aes256-gcm@openssh.com" >> /etc/ssh/sshd_config
# restart OpenSSH
systemctl restart sshd

# ALL DONE!