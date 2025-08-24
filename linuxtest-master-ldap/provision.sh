#!/usr/bin/env bash


sudo sed -i s/mirror.centos.org/vault.centos.org/g /etc/yum.repos.d/*.repo
sudo sed -i s/^#.*baseurl=http/baseurl=http/g /etc/yum.repos.d/*.repo
sudo sed -i s/^mirrorlist=http/#mirrorlist=http/g /etc/yum.repos.d/*.repo
sudo -- bash -c 'echo "sslverify=false" >> /etc/yum.conf'

if [ "$1" == "" ] ; then
	VER="56"
else
	VER="$1"
fi

printf "\nInitializing mysql.sh Version ($VER)...\n\n"

# NOTE: EPEL repo must be enabled in base.sh script per missing dependency in Percona repo:
# https://bugs.launchpad.net/percona-xtrabackup/+bug/1526636
if [[ ! -e /etc/yum.repos.d/epel.repo ]]; then yum -y install http://mirror.pnl.gov/epel/6/x86_64/epel-release-6-8.noarch.rpm; fi

# Install Percona MySQL Repo
yum install http://www.percona.com/downloads/percona-release/redhat/0.1-3/percona-release-0.1-3.noarch.rpm -y
# Install Percona MySQL Server, server headers, toolkit and Xtrabackup
yum install Percona-Server-server-$VER Percona-Server-devel-$VER percona-toolkit percona-xtrabackup -y

# Create mysql dir
if [[ ! -d /storage/db ]]; then mkdir -p /storage/db && ln -s /storage/db/ /db; fi
ln -s /var/lib/mysql/ /storage/db/mysql > /dev/null 2>&1
chown -R mysql:mysql /db/mysql

# Start MySQL Service
if pidof systemd > /dev/null ; then
	systemctl enable mysqld
	systemctl start mysqld
else
	chkconfig --add mysql
	service mysql start
fi


if ! grep password ~/.my.cnf > /dev/null 2>&1
then
	printf "Configure desired mysql_secure_installation defaults..."
	# This is not about local security, it about making sure root can't get attacked remotly easily by guessing no password.
	# The password is always initially set here and then populated in the ~/.my.cnf file
	mysql --user=root <<- EOF
	UPDATE mysql.user SET Password=PASSWORD('Secret1') WHERE User='root';
	DELETE FROM mysql.user WHERE User='';
	DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
	DROP DATABASE IF EXISTS test;
	DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
	FLUSH PRIVILEGES;
	EOF

	# ~/.my.cnf should never be there already when this script runs - it always initializes the mysql install
	printf "\nSetting up .my.cnf..."
	printf "
	[client]
	password=Secret1" >> ~/.my.cnf

	printf "
	[client]
	password=Secret1" >> /home/vagrant/.my.cnf

	printf "Done.\n"
fi


yum install -y httpd
sudo systemctl start  httpd.service

# provision.sh — Vagrant provisioner for OpenLDAP server + basic client config
# Target: CentOS 7 (systemd)
# Based on your command log; made non-interactive & idempotent.


#--- CHATGPT GENERATED CONTENT BELOW BASED ON THE CONTEXT OF Commands_ran.txt "

### --- Config you can tweak ---
BASE_DC1="srv"
BASE_DC2="world"
ORG_NAME="Server World"
ROOT_DN="cn=Manager,dc=${BASE_DC1},dc=${BASE_DC2}"
BASE_DN="dc=${BASE_DC1},dc=${BASE_DC2}"

# Set passwords (plain) — change as you like
ROOT_PW_PLAIN="1"
USER_PW_PLAIN="1"

# Example demo user
USER_UID="cent"
USER_CN="Cent"
USER_SN="Linux"
USER_UIDNUM="1000"
USER_GIDNUM="1000"
USER_HOME="/home/${USER_UID}"

LDAP_SERVER_HOST="dlp.${BASE_DC1}.${BASE_DC2}"

# Workspace for temp files
WORKDIR="/root/ldapsetup"
mkdir -p "${WORKDIR}"

log() { echo -e "\n==> $*\n"; }

### --- Packages & service ---
log "Installing OpenLDAP server/clients and tools..."
yum -y install openldap-servers openldap-clients nss-pam-ldapd >/dev/null

# Ensure DB_CONFIG exists with proper ownership
if [ ! -f /var/lib/ldap/DB_CONFIG ]; then
  log "Seeding /var/lib/ldap/DB_CONFIG"
  cp /usr/share/openldap-servers/DB_CONFIG.example /var/lib/ldap/DB_CONFIG
  chown ldap:ldap /var/lib/ldap/DB_CONFIG
fi

# Enable & start slapd
log "Enabling and starting slapd..."
systemctl enable slapd >/dev/null
systemctl restart slapd

### --- Hash passwords ---
ROOT_PW_HASH="$(slappasswd -s "${ROOT_PW_PLAIN}")"
USER_PW_HASH="$(slappasswd -s "${USER_PW_PLAIN}")"

### --- Set cn=config root password (olcRootPW) ---
CHROOTPW_LDIF="${WORKDIR}/chrootpw.ldif"
cat > "${CHROOTPW_LDIF}" <<EOF
dn: olcDatabase={0}config,cn=config
changetype: modify
add: olcRootPW
olcRootPW: ${ROOT_PW_HASH}
EOF

# Apply only if not already set
if ! ldapsearch -Y EXTERNAL -H ldapi:/// -b "olcDatabase={0}config,cn=config" olcRootPW 2>/dev/null | grep -q '^olcRootPW:'; then
  log "Configuring olcRootPW under cn=config"
  ldapadd -Y EXTERNAL -H ldapi:/// -f "${CHROOTPW_LDIF}"
else
  log "olcRootPW already configured — skipping."
fi

### --- Load core schemas (cosine, nis, inetorgperson) ---
log "Ensuring cosine/nis/inetorgperson schemas are loaded..."
for schema in cosine nis inetorgperson; do
  if ! ldapsearch -Y EXTERNAL -H ldapi:/// -b "cn=schema,cn=config" cn | grep -q "cn=${schema},"; then
    ldapadd -Y EXTERNAL -H ldapi:/// -f "/etc/openldap/schema/${schema}.ldif"
  else
    echo " - ${schema} already present."
  fi
done

### --- Configure database suffix, rootDN, access controls (hdb as in your notes) ---
CHDOMAIN_LDIF="${WORKDIR}/chdomain.ldif"
cat > "${CHDOMAIN_LDIF}" <<EOF
dn: olcDatabase={1}monitor,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to * by dn.base="gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth" read by dn.base="${ROOT_DN}" read by * none

dn: olcDatabase={2}hdb,cn=config
changetype: modify
replace: olcSuffix
olcSuffix: ${BASE_DN}

dn: olcDatabase={2}hdb,cn=config
changetype: modify
replace: olcRootDN
olcRootDN: ${ROOT_DN}

dn: olcDatabase={2}hdb,cn=config
changetype: modify
add: olcRootPW
olcRootPW: ${ROOT_PW_HASH}

dn: olcDatabase={2}hdb,cn=config
changetype: modify
add: olcAccess
olcAccess: {0}to attrs=userPassword,shadowLastChange by dn="${ROOT_DN}" write by anonymous auth by self write by * none
olcAccess: {1}to dn.base="" by * read
olcAccess: {2}to * by dn="${ROOT_DN}" write by * read
EOF

# Apply once (check for olcSuffix match)
if ! ldapsearch -Y EXTERNAL -H ldapi:/// -b "olcDatabase={2}hdb,cn=config" olcSuffix 2>/dev/null | grep -q "olcSuffix: ${BASE_DN}"; then
  log "Applying database suffix/rootDN/ACLs"
  ldapmodify -Y EXTERNAL -H ldapi:/// -f "${CHDOMAIN_LDIF}"
else
  log "Database appears configured — skipping."
fi

### --- Seed base DIT (dc=..., Manager, ou=People, ou=Group) ---
BASEDOMAIN_LDIF="${WORKDIR}/basedomain.ldif"
cat > "${BASEDOMAIN_LDIF}" <<EOF
dn: ${BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${ORG_NAME}
dc: ${BASE_DC1^}

dn: ${ROOT_DN}
objectClass: organizationalRole
cn: Manager
description: Directory Manager

dn: ou=People,${BASE_DN}
objectClass: organizationalUnit
ou: People

dn: ou=Group,${BASE_DN}
objectClass: organizationalUnit
ou: Group
EOF

if ! ldapsearch -x -b "${BASE_DN}" -s base dn 2>/dev/null | grep -q "^dn: ${BASE_DN}"; then
  log "Adding base DIT"
  ldapadd -x -D "${ROOT_DN}" -w "${ROOT_PW_PLAIN}" -f "${BASEDOMAIN_LDIF}"
else
  log "Base DIT already present — skipping."
fi

### --- Add example user & group (cent / gid 1000) ---
LDAPUSER_LDIF="${WORKDIR}/ldapuser.ldif"
cat > "${LDAPUSER_LDIF}" <<EOF
dn: uid=${USER_UID},ou=People,${BASE_DN}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: ${USER_CN}
sn: ${USER_SN}
userPassword: ${USER_PW_HASH}
loginShell: /bin/bash
uidNumber: ${USER_UIDNUM}
gidNumber: ${USER_GIDNUM}
homeDirectory: ${USER_HOME}

dn: cn=${USER_UID},ou=Group,${BASE_DN}
objectClass: posixGroup
cn: ${USER_UID}
gidNumber: ${USER_GIDNUM}
memberUid: ${USER_UID}
EOF

if ! ldapsearch -x -b "uid=${USER_UID},ou=People,${BASE_DN}" dn 2>/dev/null | grep -q "^dn: uid=${USER_UID},"; then
  log "Creating demo user/group (${USER_UID})"
  ldapadd -x -D "${ROOT_DN}" -w "${ROOT_PW_PLAIN}" -f "${LDAPUSER_LDIF}"
else
  log "Demo user ${USER_UID} already exists — skipping."
fi

### --- Client auth (nss-pam-ldapd + authconfig) ---
log "Configuring system authentication to LDAP (authconfig)..."
authconfig --enableldap \
  --enableldapauth \
  --ldapserver="${LDAP_SERVER_HOST}" \
  --ldapbasedn="${BASE_DN}" \
  --enablemkhomedir \
  --update

log "Provisioning complete. You can test with, e.g.:"
echo "  ldapsearch -x -D ${ROOT_DN} -w '${ROOT_PW_PLAIN}' -b '${BASE_DN}' '(uid=${USER_UID})' cn uidNumber gidNumber"



echo "You should be able to reach http://localhost:8080/ now   (unless the port was redirected.)"
