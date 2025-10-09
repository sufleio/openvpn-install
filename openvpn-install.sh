#!/bin/bash

if grep -qs "14.04" /etc/os-release; then
	echo "Ubuntu 14.04 is too old and not supported"
	exit
fi

if grep -qs "jessie" /etc/os-release; then
	echo "Debian 8 is too old and not supported"
	exit
fi

if grep -qs "CentOS release 6" /etc/redhat-release; then
	echo "CentOS 6 is too old and not supported"
	exit
fi

if grep -qs "Ubuntu 16.04" /etc/os-release; then
	echo 'Ubuntu 16.04 is no longer supported in the current version of openvpn-install
Use an older version if Ubuntu 16.04 support is needed: https://git.io/vpn1604'
	exit
fi

# Detect Debian users running the script with "sh" instead of bash
if readlink /proc/$$/exe | grep -q "dash"; then
	echo "This script needs to be run with bash, not sh"
	exit
fi

if [[ "$EUID" -ne 0 ]]; then
	echo "Sorry, you need to run this as root"
	exit
fi

if [[ ! -e /dev/net/tun ]]; then
	echo "The TUN device is not available
You need to enable TUN before running this script"
	exit
fi

if ! iptables -t nat -nL &>/dev/null; then
	echo "Unable to initialize the iptables/netfilter NAT table, setup can't continue.
Make sure that your system has iptables/netfilter available.
If using OpenVZ, ask your provider to enable full netfilter support."
	exit
fi

if [[ -e /etc/debian_version ]]; then
	group_name="nogroup"
	if grep -qs "20.04" /etc/os-release; then
		os="ubuntu-20.04"
	else
		os="debian"
	fi
elif [[ -e /etc/centos-release || -e /etc/redhat-release ]]; then
	os="centos"
	group_name="nobody"
elif grep -qs "Amazon Linux" /etc/system-release; then
	os="amazon-linux"
	group_name="nobody"
else
	echo "Looks like you aren't running this installer on Debian, Ubuntu, CentOS or Amazon Linux"
	exit
fi

new_client () {
	# Generates the custom client.ovpn
	{
	cat /etc/openvpn/server/client-common.txt
	echo "<ca>"
	cat /etc/openvpn/server/easy-rsa/pki/ca.crt
	echo "</ca>"
	echo "<cert>"
	sed -ne '/BEGIN CERTIFICATE/,$ p' /etc/openvpn/server/easy-rsa/pki/issued/"$1".crt
	echo "</cert>"
	echo "<key>"
	cat /etc/openvpn/server/easy-rsa/pki/private/"$1".key
	echo "</key>"
	echo "<tls-crypt>"
	sed -ne '/BEGIN OpenVPN Static key/,$ p' /etc/openvpn/server/tc.key
	echo "</tls-crypt>"
	} > ~/"$1".ovpn
	
	# Only set up 2FA if enabled
	if [[ "$ENABLE_2FA" == "true" ]]; then
		useradd $1 2>/dev/null
		google-authenticator -t -d -r3 -R30 -f -l $1-vpn -s /etc/openvpn/google-authenticator/$1
		chown gauth. /etc/openvpn/google-authenticator/$1
	fi
}

if [[ -e /etc/openvpn/server/server.conf ]]; then
	# Check if 2FA is enabled in existing setup
	if grep -q "plugin.*openvpn-plugin-auth-pam.so" /etc/openvpn/server/server.conf; then
		ENABLE_2FA="true"
	else
		ENABLE_2FA="false"
	fi
	
	while :
	do
	clear
		echo "Looks like OpenVPN is already installed."
		if [[ "$ENABLE_2FA" == "true" ]]; then
			echo "(2FA is ENABLED)"
		else
			echo "(2FA is DISABLED - Certificate-only authentication)"
		fi
		echo
		echo "What do you want to do?"
		echo "   1) Add a new user"
		echo "   2) Revoke an existing user"
		echo "   3) Remove OpenVPN"
		echo "   4) Exit"
		read -p "Select an option: " option
		until [[ "$option" =~ ^[1-4]$ ]]; do
			echo "$option: invalid selection."
			read -p "Select an option: " option
		done
		case "$option" in
			1)
			echo
			echo "Tell me a name for the client certificate."
			read -p "Client name: " unsanitized_client
			client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
			while [[ -z "$client" || -e /etc/openvpn/server/easy-rsa/pki/issued/"$client".crt ]]; do
				echo "$client: invalid client name."
				read -p "Client name: " unsanitized_client
				client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
			done
			cd /etc/openvpn/server/easy-rsa/
			EASYRSA_CERT_EXPIRE=3650 ./easyrsa build-client-full "$client" nopass
			# Generates the custom client.ovpn
			new_client "$client"
			echo
			echo "Client $client added, configuration is available at:" ~/"$client.ovpn"
			if [[ "$ENABLE_2FA" == "true" ]]; then
				echo
				echo "IMPORTANT: 2FA is enabled. Your Google Authenticator secret is stored in:"
				echo "/etc/openvpn/google-authenticator/$client"
				echo
				echo "When connecting, use:"
				echo "  Username: $client"
				echo "  Password: [6-digit code from your authenticator app]"
			fi
			exit
			;;
			2)
			# This option could be documented a bit better and maybe even be simplified
			# ...but what can I say, I want some sleep too
			number_of_clients=$(tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep -c "^V")
			if [[ "$number_of_clients" = 0 ]]; then
				echo
				echo "You have no existing clients!"
				exit
			fi
			echo
			echo "Select the existing client certificate you want to revoke:"
			tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | nl -s ') '
			read -p "Select one client: " client_number
			until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$number_of_clients" ]]; do
				echo "$client_number: invalid selection."
				read -p "Select one client: " client_number
			done
			client=$(tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | sed -n "$client_number"p)
			echo
			read -p "Do you really want to revoke access for client $client? [y/N]: " revoke
			until [[ "$revoke" =~ ^[yYnN]*$ ]]; do
				echo "$revoke: invalid selection."
				read -p "Do you really want to revoke access for client $client? [y/N]: " revoke
			done
			if [[ "$revoke" =~ ^[yY]$ ]]; then
				cd /etc/openvpn/server/easy-rsa/
				./easyrsa --batch revoke "$client"
				EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
				rm -f pki/reqs/"$client".req
				rm -f pki/private/"$client".key
				rm -f pki/issued/"$client".crt
				rm -f /etc/openvpn/server/crl.pem
				cp /etc/openvpn/server/easy-rsa/pki/crl.pem /etc/openvpn/server/crl.pem
				# CRL is read with each client connection, when OpenVPN is dropped to nobody
				chown nobody:"$group_name" /etc/openvpn/server/crl.pem
				# Clean up 2FA files if they exist
				if [[ -f /etc/openvpn/google-authenticator/"$client" ]]; then
					rm -f /etc/openvpn/google-authenticator/"$client"
				fi
				userdel "$client" 2>/dev/null
				echo
				echo "Certificate for client $client revoked!"
			else
				echo
				echo "Certificate revocation for client $client aborted!"
			fi
			exit
			;;
			3)
			echo
			read -p "Do you really want to remove OpenVPN? [y/N]: " remove
			until [[ "$remove" =~ ^[yYnN]*$ ]]; do
				echo "$remove: invalid selection."
				read -p "Do you really want to remove OpenVPN? [y/N]: " remove
			done
			if [[ "$remove" =~ ^[yY]$ ]]; then
				port=$(grep '^port ' /etc/openvpn/server/server.conf | cut -d " " -f 2)
				protocol=$(grep '^proto ' /etc/openvpn/server/server.conf | cut -d " " -f 2)
				if pgrep firewalld; then
					ip=$(firewall-cmd --direct --get-rules ipv4 nat POSTROUTING | grep '\-s 10.8.0.0/24 '"'"'!'"'"' -d 10.8.0.0/24 -j SNAT --to ' | cut -d " " -f 10)
					# Using both permanent and not permanent rules to avoid a firewalld reload.
					firewall-cmd --remove-port="$port"/"$protocol"
					firewall-cmd --zone=trusted --remove-source=10.8.0.0/24
					firewall-cmd --permanent --remove-port="$port"/"$protocol"
					firewall-cmd --permanent --zone=trusted --remove-source=10.8.0.0/24
					firewall-cmd --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
					firewall-cmd --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
				else
					systemctl disable --now openvpn-iptables.service
					rm -f /etc/systemd/system/openvpn-iptables.service
				fi
				if sestatus 2>/dev/null | grep "Current mode" | grep -q "enforcing" && [[ "$port" != 1194 ]]; then
					semanage port -d -t openvpn_port_t -p "$protocol" "$port"
				fi
				systemctl disable --now openvpn-server@server.service
				rm -rf /etc/openvpn/server
				rm -rf /etc/openvpn/google-authenticator
				rm -f /etc/systemd/system/openvpn-server@server.service.d/disable-limitnproc.conf
				rm -f /etc/sysctl.d/30-openvpn-forward.conf
				if [[ "$os" == "debian" ]] || [[ "$os" == "ubuntu-20.04" ]]; then
					apt-get remove --purge -y openvpn
				else
					yum remove openvpn -y
				fi
				echo
				echo "OpenVPN removed!"
			else
				echo
				echo "Removal aborted!"
			fi
			exit
			;;
			4) exit;;
		esac
	done
else
	clear
	echo "Welcome to this OpenVPN "road warrior" installer!"
	echo
	echo "I need to ask you a few questions before starting setup."
	echo "You can use the default options and just press enter if you are ok with them."
	# If system has a single IPv4, it is selected automatically. Else, ask the user
	if [[ $(ip addr | grep inet | grep -v inet6 | grep -vEc '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}') -eq 1 ]]; then
		ip=$(ip addr | grep inet | grep -v inet6 | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
	else
		number_of_ips=$(ip addr | grep inet | grep -v inet6 | grep -vEc '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
		echo
		echo "What IPv4 address should the OpenVPN server bind to?"
		ip addr | grep inet | grep -v inet6 | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | nl -s ') '
		read -p "IPv4 address [1]: " ip_number
		until [[ -z "$ip_number" || "$ip_number" =~ ^[0-9]+$ && "$ip_number" -le "$number_of_ips" ]]; do
			echo "$ip_number: invalid selection."
			read -p "IPv4 address [1]: " ip_number
		done
		[[ -z "$ip_number" ]] && ip_number="1"
		ip=$(ip addr | grep inet | grep -v inet6 | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | sed -n "$ip_number"p)
	fi
	# If $IP is a private IP address, the server must be behind NAT
	if echo "$ip" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
		echo
		echo "This server is behind NAT. What is the public IPv4 address or hostname?"
		get_public_ip=$(wget -4qO- "http://whatismyip.akamai.com/" || curl -4Ls "http://whatismyip.akamai.com/")
		read -p "Public IPv4 address / hostname [$get_public_ip]: " public_ip
		[ -z "$public_ip" ] && public_ip="$get_public_ip"
	fi
	echo
	echo "Which protocol do you want for OpenVPN connections?"
	echo "   1) UDP (recommended)"
	echo "   2) TCP"
	read -p "Protocol [1]: " protocol
	until [[ -z "$protocol" || "$protocol" =~ ^[12]$ ]]; do
		echo "$protocol: invalid selection."
		read -p "Protocol [1]: " protocol
	done
	case "$protocol" in
		1|"")
		protocol=udp
		;;
		2)
		protocol=tcp
		;;
	esac
	echo
	echo "What port do you want OpenVPN listening to?"
	read -p "Port [1194]: " port
	until [[ -z "$port" || "$port" =~ ^[0-9]+$ && "$port" -le 65535 ]]; do
		echo "$port: invalid selection."
		read -p "Port [1194]: " port
	done
	[[ -z "$port" ]] && port="1194"
	echo
	echo "Which DNS do you want to use with the VPN?"
	echo "   1) Current system resolvers"
	echo "   2) 1.1.1.1"
	echo "   3) Google"
	echo "   4) OpenDNS"
	echo "   5) Verisign"
	read -p "DNS [1]: " dns
	until [[ -z "$dns" || "$dns" =~ ^[1-5]$ ]]; do
		echo "$dns: invalid selection."
		read -p "DNS [1]: " dns
	done
	echo
	echo "Do you want to enable Two-Factor Authentication (2FA)?"
	echo "   1) No - Certificate only (recommended for personal use, simpler)"
	echo "   2) Yes - Certificate + Google Authenticator (maximum security)"
	echo
	echo "Note: If you choose 2FA, you'll need a mobile authenticator app."
	read -p "Enable 2FA? [1]: " enable_2fa_choice
	until [[ -z "$enable_2fa_choice" || "$enable_2fa_choice" =~ ^[12]$ ]]; do
		echo "$enable_2fa_choice: invalid selection."
		read -p "Enable 2FA? [1]: " enable_2fa_choice
	done
	case "$enable_2fa_choice" in
		2)
		ENABLE_2FA="true"
		echo "2FA will be enabled. You'll need to scan QR codes or enter secret keys manually."
		;;
		1|"")
		ENABLE_2FA="false"
		echo "2FA disabled. Using certificate-only authentication."
		;;
	esac
	echo
	echo "Finally, tell me a name for the client certificate."
	read -p "Client name [client]: " unsanitized_client
	# Allow a limited set of characters to avoid conflicts
	client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
	[[ -z "$client" ]] && client="client"
	echo
	echo "Okay, that was all I needed. We are ready to set up your OpenVPN server now."
	read -n1 -r -p "Press any key to continue..."
	# If running inside a container, disable LimitNPROC to prevent conflicts
	if systemd-detect-virt -cq; then
		mkdir /etc/systemd/system/openvpn-server@server.service.d/ 2>/dev/null
		echo "[Service]
LimitNPROC=infinity" > /etc/systemd/system/openvpn-server@server.service.d/disable-limitnproc.conf
	fi
	if [[ "$os" = "debian" ]]; then
		apt-get update
		apt-get install openvpn iptables openssl ca-certificates -y
		if [[ "$ENABLE_2FA" == "true" ]]; then
			apt-get install libqrencode3 libpam-google-authenticator -y
			addgroup gauth
			useradd -g gauth gauth
		fi
	elif [[ "$os" == "ubuntu-20.04" ]]; then
		apt-get update
		apt-get install openvpn iptables openssl ca-certificates -y
		if [[ "$ENABLE_2FA" == "true" ]]; then
			apt-get install libqrencode4 libpam-google-authenticator -y
			addgroup gauth
			useradd -g gauth gauth
		fi
	elif [[ "$os" == "amazon-linux" ]]; then
		amazon-linux-extras install epel -y
		yum install openvpn iptables openssl ca-certificates tar -y
		if [[ "$ENABLE_2FA" == "true" ]]; then
			yum install google-authenticator -y
			groupadd gauth
			adduser -g gauth gauth
		fi
	else
		# Else, the distro is CentOS
		yum install epel-release -y
		yum install openvpn iptables openssl ca-certificates tar -y
		if [[ "$ENABLE_2FA" == "true" ]]; then
			yum install google-authenticator -y
			groupadd gauth
			adduser -g gauth gauth
		fi
	fi
	
	if [[ "$ENABLE_2FA" == "true" ]]; then
		mkdir -p /etc/openvpn/google-authenticator
		chown gauth:gauth /etc/openvpn/google-authenticator
		chmod 0700 /etc/openvpn/google-authenticator
	fi
	
	# Get easy-rsa
	easy_rsa_url='https://github.com/OpenVPN/easy-rsa/releases/download/v3.0.5/EasyRSA-nix-3.0.5.tgz'
	wget -O ~/easyrsa.tgz "$easy_rsa_url" 2>/dev/null || curl -Lo ~/easyrsa.tgz "$easy_rsa_url"
	tar xzf ~/easyrsa.tgz -C ~/
	mv ~/EasyRSA-3.0.5/ /etc/openvpn/server/
	mv /etc/openvpn/server/EasyRSA-3.0.5/ /etc/openvpn/server/easy-rsa/
	chown -R root:root /etc/openvpn/server/easy-rsa/
	rm -f ~/easyrsa.tgz
	cd /etc/openvpn/server/easy-rsa/
	# Create the PKI, set up the CA and the server and client certificates
	./easyrsa init-pki
	./easyrsa --batch build-ca nopass
	EASYRSA_CERT_EXPIRE=3650 ./easyrsa build-server-full server nopass
	EASYRSA_CERT_EXPIRE=3650 ./easyrsa build-client-full "$client" nopass
	EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
	# Move the stuff we need
	cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/crl.pem /etc/openvpn/server
	# CRL is read with each client connection, when OpenVPN is dropped to nobody
	chown nobody:"$group_name" /etc/openvpn/server/crl.pem
	# Generate key for tls-crypt
	openvpn --genkey --secret /etc/openvpn/server/tc.key
	# Create the DH parameters file using the predefined ffdhe2048 group
	echo '-----BEGIN DH PARAMETERS-----
MIIBCAKCAQEA//////////+t+FRYortKmq/cViAnPTzx2LnFg84tNpWp4TZBFGQz
+8yTnc4kmz75fS/jY2MMddj2gbICrsRhetPfHtXV/WVhJDP1H18GbtCFY2VVPe0a
87VXE15/V8k1mE8McODmi3fipona8+/och3xWKE2rec1MKzKT0g6eXq8CrGCsyT7
YdEIqUuyyOP7uWrat2DX9GgdT0Kj3jlN9K5W7edjcrsZCwenyO4KbXCeAvzhzffi
7MA0BM0oNC9hkXL+nOmFg/+OTxIy7vKBg8P+OxtMb61zO7X8vC7CIAXFjvGDfRaD
ssbzSibBsu/6iGtCOGEoXJf//////////wIBAg==
-----END DH PARAMETERS-----' > /etc/openvpn/server/dh.pem
	# Generate server.conf
	echo "local $ip
port $port
proto $protocol
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
auth SHA512
tls-crypt tc.key
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt" > /etc/openvpn/server/server.conf
	echo 'push "redirect-gateway def1 bypass-dhcp"' >> /etc/openvpn/server/server.conf
	# DNS
	case "$dns" in
		1|"")
		# Locate the proper resolv.conf
		# Needed for systems running systemd-resolved
		if grep -q "127.0.0.53" "/etc/resolv.conf"; then
			resolv_conf="/run/systemd/resolve/resolv.conf"
		else
			resolv_conf="/etc/resolv.conf"
		fi
		# Obtain the resolvers from resolv.conf and use them for OpenVPN
		grep -v '#' "$resolv_conf" | grep nameserver | grep -E -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | while read line; do
			echo "push \"dhcp-option DNS $line\"" >> /etc/openvpn/server/server.conf
		done
		;;
		2)
		echo 'push "dhcp-option DNS 1.1.1.1"' >> /etc/openvpn/server/server.conf
		echo 'push "dhcp-option DNS 1.0.0.1"' >> /etc/openvpn/server/server.conf
		;;
		3)
		echo 'push "dhcp-option DNS 8.8.8.8"' >> /etc/openvpn/server/server.conf
		echo 'push "dhcp-option DNS 8.8.4.4"' >> /etc/openvpn/server/server.conf
		;;
		4)
		echo 'push "dhcp-option DNS 208.67.222.222"' >> /etc/openvpn/server/server.conf
		echo 'push "dhcp-option DNS 208.67.220.220"' >> /etc/openvpn/server/server.conf
		;;
		5)
		echo 'push "dhcp-option DNS 64.6.64.6"' >> /etc/openvpn/server/server.conf
		echo 'push "dhcp-option DNS 64.6.65.6"' >> /etc/openvpn/server/server.conf
		;;
	esac
	echo "keepalive 10 120
cipher AES-256-CBC
user root
group root
persist-key
persist-tun
status openvpn-status.log
verb 3
reneg-sec 28800
crl-verify crl.pem" >> /etc/openvpn/server/server.conf
	if [[ "$protocol" = "udp" ]]; then
		echo "explicit-exit-notify" >> /etc/openvpn/server/server.conf
	fi
	
	# Only add PAM authentication if 2FA is enabled
	if [[ "$ENABLE_2FA" == "true" ]]; then
		mkdir -p /usr/lib/openvpn/
		if [[ "$os" == "debian" ]] || [[ "$os" == "ubuntu-20.04" ]]; then
			echo "plugin /usr/lib/openvpn/openvpn-plugin-auth-pam.so openvpn" >> /etc/openvpn/server/server.conf
			ln -s /usr/lib/x86_64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so /usr/lib/openvpn/openvpn-plugin-auth-pam.so
			echo "auth required /lib/x86_64-linux-gnu/security/pam_google_authenticator.so secret=/etc/openvpn/google-authenticator/\${USER} user=gauth forward_pass" > /etc/pam.d/openvpn
		else
			# CentOS or Amazon Linux - use native PAM plugin
			echo "plugin /usr/lib64/openvpn/plugins/openvpn-plugin-auth-pam.so openvpn" >> /etc/openvpn/server/server.conf
			echo "auth required pam_google_authenticator.so secret=/etc/openvpn/google-authenticator/\${USER} user=gauth forward_pass" > /etc/pam.d/openvpn
		fi
	fi
	
	# Enable net.ipv4.ip_forward for the system
	echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/30-openvpn-forward.conf
	# Enable without waiting for a reboot or service restart
	echo 1 > /proc/sys/net/ipv4/ip_forward
	if pgrep firewalld; then
		# Using both permanent and not permanent rules to avoid a firewalld
		# reload.
		# We don't use --add-service=openvpn because that would only work with
		# the default port and protocol.
		firewall-cmd --add-port="$port"/"$protocol"
		firewall-cmd --zone=trusted --add-source=10.8.0.0/24
		firewall-cmd --permanent --add-port="$port"/"$protocol"
		firewall-cmd --permanent --zone=trusted --add-source=10.8.0.0/24
		# Set NAT for the VPN subnet
		firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
		firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
	else
		# Detect network interface dynamically
		default_interface=$(ip route | grep default | awk '{print $5}' | head -n1)
		# Create a service to set up persistent iptables rules
		echo "[Unit]
Before=network.target
[Service]
Type=oneshot
ExecStart=/sbin/iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $default_interface -j MASQUERADE
ExecStart=/sbin/iptables -I INPUT -p $protocol --dport $port -j ACCEPT
ExecStart=/sbin/iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT
ExecStart=/sbin/iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=/sbin/iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o $default_interface -j MASQUERADE
ExecStop=/sbin/iptables -D INPUT -p $protocol --dport $port -j ACCEPT
ExecStop=/sbin/iptables -D FORWARD -s 10.8.0.0/24 -j ACCEPT
ExecStop=/sbin/iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target" > /etc/systemd/system/openvpn-iptables.service
		systemctl enable --now openvpn-iptables.service
	fi
	# If SELinux is enabled and a custom port was selected, we need this
	if sestatus 2>/dev/null | grep "Current mode" | grep -q "enforcing" && [[ "$port" != 1194 ]]; then
		# Install semanage if not already present
		if ! hash semanage 2>/dev/null; then
			if grep -qs "CentOS Linux release 7" "/etc/centos-release"; then
				yum install policycoreutils-python -y
			else
				yum install policycoreutils-python-utils -y
			fi
		fi
		semanage port -a -t openvpn_port_t -p "$protocol" "$port"
	fi
	# If the server is behind a NAT, use the correct IP address
	if [[ "$public_ip" != "" ]]; then
		ip="$public_ip"
	fi
	# client-common.txt is created so we have a template to add further users later
	echo "client
dev tun
proto $protocol
remote $ip $port
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
cipher AES-256-CBC
verb 3
reneg-sec 28800" > /etc/openvpn/server/client-common.txt
	
	# Only add auth-user-pass if 2FA is enabled
	if [[ "$ENABLE_2FA" == "true" ]]; then
		echo "auth-user-pass" >> /etc/openvpn/server/client-common.txt
	fi
	
	# Enable and start the OpenVPN service
	systemctl enable --now openvpn-server@server.service
	# Generates the custom client.ovpn
	new_client "$client"
	echo
	echo "Finished!"
	echo
	echo "Your client configuration is available at:" ~/"$client.ovpn"
	if [[ "$ENABLE_2FA" == "true" ]]; then
		echo
		echo "================================================"
		echo "IMPORTANT: 2FA is ENABLED"
		echo "================================================"
		echo "Your Google Authenticator secret is stored in:"
		echo "/etc/openvpn/google-authenticator/$client"
		echo
		echo "When connecting to VPN, you'll need:"
		echo "  Username: $client"
		echo "  Password: [6-digit code from your authenticator app]"
		echo
		echo "Add the secret to your authenticator app (Google Authenticator, Authy, etc.)"
		echo "================================================"
	else
		echo
		echo "Certificate-only authentication is configured."
		echo "Simply import the .ovpn file to connect - no password needed."
	fi
	echo
	echo "If you want to add more clients, just run this script again!"
fi