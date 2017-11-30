#!/bin/sh

##
## Setup the OpenStack controller node.
##

set -x

DIRNAME=`dirname $0`

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "$DIRNAME/setup-lib.sh"

if [ "$HOSTNAME" != "$CONTROLLER" ]; then
    exit 0;
fi

logtstart "controller"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

#
# openstack CLI commands seem flakey sometimes on Kilo and Liberty.
# Don't know if it's WSGI, mysql dropping connections, an NTP
# thing... but until it gets solved more permanently, have to retry :(.
#
__openstack() {
    __err=1
    __debug=
    __times=0
    while [ $__times -lt 16 -a ! $__err -eq 0 ]; do
	openstack $__debug "$@"
	__err=$?
        if [ $__err -eq 0 ]; then
            break
        fi
	__debug=" --debug "
	__times=`expr $__times + 1`
	if [ $__times -gt 1 ]; then
	    echo "ERROR: openstack command failed: sleeping and trying again!"
	    sleep 8
	fi
    done
}

#
# We're going to spin off our image downloader/configurator to better
# parallelize.  So make sure it has the packages it needs.
#
maybe_install_packages qemu-utils wget lockfile-progs rpm
if [ "$ARCH" = "aarch64" ]; then
    # need growpart
    maybe_install_packages cloud-guest-utils
fi

maybe_install_packages pssh
PSSH='/usr/bin/parallel-ssh -t 0 -O StrictHostKeyChecking=no '

# Make sure our repos are setup.
#apt-get install ubuntu-cloud-keyring
#echo "deb http://ubuntu-cloud.archive.canonical.com/ubuntu" \
#    "trusty-updates/juno main" > /etc/apt/sources.list.d/cloudarchive-juno.list

#sudo add-apt-repository ppa:ubuntu-cloud-archive/juno-staging 

#
# Setup mail to users
#
maybe_install_packages dma
echo "$PFQDN" > /etc/mailname
sleep 2
echo "Your OpenStack instance is setting up on `hostname` ." \
    |  mail -s "OpenStack Instance Setting Up" ${SWAPPER_EMAIL} &

#
# Fire off the image downloader/configurator in the background.
#
$DIRNAME/setup-images.sh >> $OURDIR/setup-images.log 2>&1 &

#
# If we're >= Kilo, we might need the openstack CLI command.
#
if [ $OSVERSION -ge $OSKILO ]; then
    maybe_install_packages python-openstackclient
fi

#
# This is a nasty bug in oslo_service; see 
# https://review.openstack.org/#/c/256267/
#
if [ $OSVERSION -ge $OSKILO -a $OSVERSION -lt $OSNEWTON ]; then
    maybe_install_packages python-oslo.service
    patch -d / -p0 < $DIRNAME/etc/oslo_service-liberty-sig-MAINLOOP.patch
fi

#
# Install the database
#
if [ -z "${DB_ROOT_PASS}" ]; then
    logtstart "database"
    maybe_install_packages mariadb-server $DBDPACKAGE
    service_stop mysql
    # Change the root password; secure the users/dbs.
    mysqld_safe --skip-grant-tables --skip-networking &
    sleep 8
    DB_ROOT_PASS=`$PSWDGEN`
    # This does what mysql_secure_installation does on Ubuntu
    echo "use mysql; update user set password=PASSWORD(\"${DB_ROOT_PASS}\") where User='root'; delete from user where User=''; delete from user where User='root' and Host not in ('localhost', '127.0.0.1', '::1'); drop database test; delete from db where Db='test' or Db='test\\_%'; flush privileges;" | mysql -u root 
    # Shutdown our unprotected server
    mysqladmin --password=${DB_ROOT_PASS} shutdown
    # Put it on the management network and set recommended settings
    echo "[mysqld]" >> /etc/mysql/my.cnf
    echo "bind-address = $MGMTIP" >> /etc/mysql/my.cnf
    echo "default-storage-engine = innodb" >> /etc/mysql/my.cnf
    echo "innodb_file_per_table" >> /etc/mysql/my.cnf
    echo "collation-server = utf8_general_ci" >> /etc/mysql/my.cnf
    echo "init-connect = 'SET NAMES utf8'" >> /etc/mysql/my.cnf
    echo "character-set-server = utf8" >> /etc/mysql/my.cnf
    echo "max_connections = 4096" >> /etc/mysql/my.cnf
    # Restart it!
    service_restart mysql
    service_enable mysql
    # Save the passwd
    echo "DB_ROOT_PASS=\"${DB_ROOT_PASS}\"" >> $SETTINGS

    if [ -z "${MGMTLAN}" -a $OSVERSION -ge $OSLIBERTY ]; then
        # Make sure mysqld won't start until after the openvpn
	# mgmt net is up.
	cat <<EOF >/etc/init.d/legacy-openvpn-net-waiter
#!/bin/bash
#
### BEGIN INIT INFO
# Provides:          legacy-openvpn-net-waiter
# Required-Start:    \$network openvpn
# Required-Stop:
# Should-Start:      \$network openvpn
# X-Start-Before:    mysql
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Waits for an IP address to appear on the mgmt net device.
# Description:  Waits for an IP address to appear on the mgmt net device.
### END INIT INFO
#

. /lib/lsb/init-functions

case "\${1:-''}" in
    'start')
        while [ 1 -eq 1 ]; do
            ip addr show | grep -q "$MGMTIP"
            if [ \$? -eq 0 ]; then
                log_daemon_msg "Found net device with ip addr $MGMTIP; allowing services to start" "openvpn"
                break
            else
                sleep 1
            fi
        done
        ;;
    'stop')
        exit 0
        ;;
    'restart')
        exit 0
        ;;
    *)
        exit 1
        ;;
esac

exit 0
EOF

	chmod 755 /etc/init.d/legacy-openvpn-net-waiter

	#sed -i -e 's/^# Required-Start:\(.*\)$/# Required-Start:\1 mgmt-net-waiter/' /etc/init.d/mysql
	#sed -i -e 's/^# Should-Start:\(.*\)$/# Should-Start:\1 mgmt-net-waiter/' /etc/init.d/mysql

	update-rc.d legacy-openvpn-net-waiter defaults
	update-rc.d legacy-openvpn-net-waiter enable
	#update-rc.d mysql enable
    fi
    logtend "database"
fi

#
# Install a message broker
#
if [ -z "${RABBIT_PASS}" ]; then
    logtstart "rabbit"
    maybe_install_packages rabbitmq-server

    service_restart rabbitmq-server
    service_enable rabbitmq-server
    rabbitmqctl start_app
    while [ ! $? -eq 0 ]; do
	sleep 1
	rabbitmqctl start_app
    done

    if [ $OSVERSION -lt $OSNEWTON ]; then
	cat <<EOF > /etc/rabbitmq/rabbitmq.config
[
 {rabbit,
  [
   {loopback_users, []}
  ]}
]
.
EOF
    fi

    if [ ${OSCODENAME} = "juno" ]; then
	RABBIT_USER="guest"
    else
	RABBIT_USER="openstack"
	rabbitmqctl add_vhost /
    fi
    RABBIT_PASS=`$PSWDGEN`
    RABBIT_URL="rabbit://${RABBIT_USER}:${RABBIT_PASS}@${CONTROLLER}"
    rabbitmqctl change_password $RABBIT_USER $RABBIT_PASS
    if [ ! $? -eq 0 ]; then
	rabbitmqctl add_user ${RABBIT_USER} ${RABBIT_PASS}
	rabbitmqctl set_permissions ${RABBIT_USER} ".*" ".*" ".*"
    fi
    # Save the passwd
    echo "RABBIT_USER=\"${RABBIT_USER}\"" >> $SETTINGS
    echo "RABBIT_PASS=\"${RABBIT_PASS}\"" >> $SETTINGS
    echo "RABBIT_URL=\"${RABBIT_URL}\"" >> $SETTINGS

    rabbitmqctl stop_app
    service_restart rabbitmq-server
    rabbitmqctl start_app
    while [ ! $? -eq 0 ]; do
	sleep 1
	rabbitmqctl start_app
    done

    if [ -z "${MGMTLAN}" -a $OSVERSION -ge $OSLIBERTY ]; then
        # Make sure rabbitmq won't start until after the openvpn
	# mgmt net is up.
	cat <<EOF >/etc/systemd/system/openvpn-net-waiter.service
[Unit]
Description=OpenVPN Device Waiter
After=network.target network-online.target local-fs.target
Wants=network.target
Before=rabbitmq-server.service
Requires=rabbitmq-server.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/init.d/legacy-openvpn-net-waiter start
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

	systemctl enable openvpn-net-waiter.service
    fi
    logtend "rabbit"
fi

#
# If Keystone API Version v3, we have to supply a --domain sometimes.
#
DOMARG=""
#if [ $OSVERSION -gt $OSKILO ]; then
if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
    DOMARG="--domain default"
fi

#
# Always install memcache now.
#
if [ -z "${MEMCACHE_DONE}" ]; then
    logtstart "memcache"
    maybe_install_packages memcached python-memcache

    # Ensure memcached also listens on private controller network
    cat <<EOF >> /etc/memcached.conf
-l ${MGMTIP}
EOF

    if [ ${HAVE_SYSTEMD} -eq 1 ]; then
	mkdir /etc/systemd/system/memcached.service.d
	cat <<EOF >/etc/systemd/system/memcached.service.d/local-ifup.conf
[Unit]
Requires=networking.service
After=networking.service
EOF
    fi
    service_restart memcached
    service_enable memcached

    echo "MEMCACHE_DONE=1" >> $SETTINGS
    logtend "memcache"
fi

#
# Install the Identity Service
#
if [ -z "${KEYSTONE_DBPASS}" ]; then
    logtstart "keystone"
    KEYSTONE_DBPASS=`$PSWDGEN`
    echo "create database keystone" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on keystone.* to 'keystone'@'localhost' identified by '$KEYSTONE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on keystone.* to 'keystone'@'%' identified by '$KEYSTONE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    maybe_install_packages keystone python-keystoneclient
    if [ $OSVERSION -ge $OSKILO ]; then
	maybe_install_packages apache2
	maybe_install_packages libapache2-mod-wsgi
    fi

    ADMIN_TOKEN=`$PSWDGEN`

    crudini --set /etc/keystone/keystone.conf DEFAULT admin_token "$ADMIN_TOKEN"
    crudini --set /etc/keystone/keystone.conf database connection \
	"${DBDSTRING}://keystone:${KEYSTONE_DBPASS}@$CONTROLLER/keystone"

    crudini --set /etc/keystone/keystone.conf token expiration ${TOKENTIMEOUT}

    if [ $OSVERSION -le $OSJUNO ]; then
	crudini --set /etc/keystone/keystone.conf token provider \
	    'keystone.token.providers.uuid.Provider'
	crudini --set /etc/keystone/keystone.conf token driver \
	    'keystone.token.persistence.backends.sql.Token'
    elif [ $OSVERSION -le $OSKILO ]; then
	crudini --set /etc/keystone/keystone.conf token provider \
	    'keystone.token.providers.uuid.Provider'
	crudini --set /etc/keystone/keystone.conf revoke driver \
	    'keystone.contrib.revoke.backends.sql.Revoke'
	if [ $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	    crudini --set /etc/keystone/keystone.conf token driver \
		'keystone.token.persistence.backends.memcache.Token'
	    crudini --set /etc/keystone/keystone.conf memcache servers \
		'localhost:11211'
	else
	    crudini --set /etc/keystone/keystone.conf token driver \
		'keystone.token.persistence.backends.sql.Token'
	fi
    elif [ $OSVERSION -le $OSMITAKA ]; then
	crudini --set /etc/keystone/keystone.conf token provider 'uuid'
	crudini --set /etc/keystone/keystone.conf revoke driver 'sql'
	if [ $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	    crudini --set /etc/keystone/keystone.conf token driver 'memcache'
	    crudini --set /etc/keystone/keystone.conf memcache servers \
		'localhost:11211'
	else
	    crudini --set /etc/keystone/keystone.conf token driver 'sql'
	fi
    else
	crudini --set /etc/keystone/keystone.conf token provider fernet
	
	if [ $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	    crudini --set /etc/keystone/keystone.conf token driver 'memcache'
	    crudini --set /etc/keystone/keystone.conf memcache servers \
		'localhost:11211'
	else
	    crudini --set /etc/keystone/keystone.conf token driver 'sql'
	fi
    fi

    crudini --set /etc/keystone/keystone.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/keystone/keystone.conf DEFAULT debug ${DEBUG_LOGGING}

    su -s /bin/sh -c "/usr/bin/keystone-manage db_sync" keystone

    if [ $OSVERSION -ge $OSNEWTON ]; then
	keystone-manage fernet_setup --keystone-user keystone \
	    --keystone-group keystone
	keystone-manage credential_setup --keystone-user keystone \
	    --keystone-group keystone
    fi

    if [ $OSVERSION -eq $OSKILO -a $KEYSTONEUSEWSGI -eq 1 ]; then
	cat <<EOF >/etc/apache2/sites-available/wsgi-keystone.conf
Listen 5000
Listen 35357

<VirtualHost *:5000>
    WSGIDaemonProcess keystone-public processes=5 threads=1 user=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-public
    WSGIScriptAlias / /var/www/cgi-bin/keystone/main
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
      ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    LogLevel info
    ErrorLog /var/log/apache2/keystone-error.log
    CustomLog /var/log/apache2/keystone-access.log combined
</VirtualHost>

<VirtualHost *:35357>
    WSGIDaemonProcess keystone-admin processes=5 threads=1 user=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-admin
    WSGIScriptAlias / /var/www/cgi-bin/keystone/admin
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
      ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    LogLevel info
    ErrorLog /var/log/apache2/keystone-error.log
    CustomLog /var/log/apache2/keystone-access.log combined
</VirtualHost>
EOF

	ln -s /etc/apache2/sites-available/wsgi-keystone.conf \
	    /etc/apache2/sites-enabled

	mkdir -p /var/www/cgi-bin/keystone
	wget -O /var/www/cgi-bin/keystone/admin "http://git.openstack.org/cgit/openstack/keystone/plain/httpd/keystone.py?h=stable/${OSCODENAME}"
	if [ ! $? -eq 0 ]; then
            # Try the EOL version...
            wget -O /var/www/cgi-bin/keystone/admin "http://git.openstack.org/cgit/openstack/keystone/plain/httpd/keystone.py?h=${OSCODENAME}-eol"
	fi
	cp -p /var/www/cgi-bin/keystone/admin /var/www/cgi-bin/keystone/main 
	chown -R keystone:keystone /var/www/cgi-bin/keystone
	chmod 755 /var/www/cgi-bin/keystone/*
    elif [ $OSVERSION -ge $OSLIBERTY -a $KEYSTONEUSEWSGI -eq 1 \
	   -a $OSVERSION -lt $OSNEWTON ]; then
	cat <<EOF >/etc/apache2/sites-available/wsgi-keystone.conf
Listen 5000
Listen 35357

<VirtualHost *:5000>
    WSGIDaemonProcess keystone-public processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-public
    WSGIScriptAlias / /usr/bin/keystone-wsgi-public
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
      ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    ErrorLog /var/log/apache2/keystone.log
    CustomLog /var/log/apache2/keystone_access.log combined

    <Directory /usr/bin>
        <IfVersion >= 2.4>
            Require all granted
        </IfVersion>
        <IfVersion < 2.4>
            Order allow,deny
            Allow from all
        </IfVersion>
    </Directory>
</VirtualHost>

<VirtualHost *:35357>
    WSGIDaemonProcess keystone-admin processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-admin
    WSGIScriptAlias / /usr/bin/keystone-wsgi-admin
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
      ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    ErrorLog /var/log/apache2/keystone.log
    CustomLog /var/log/apache2/keystone_access.log combined

    <Directory /usr/bin>
        <IfVersion >= 2.4>
            Require all granted
        </IfVersion>
        <IfVersion < 2.4>
            Order allow,deny
            Allow from all
        </IfVersion>
    </Directory>
</VirtualHost>
EOF

	ln -s /etc/apache2/sites-available/wsgi-keystone.conf \
	    /etc/apache2/sites-enabled
    fi

    if [ $OSVERSION -le $OSJUNO -o $KEYSTONEUSEWSGI -eq 0 ]; then
	service_restart keystone
	service_enable keystone
    else
	service_stop keystone
	service_disable keystone

	service_restart apache2
	service_enable apache2
    fi
    rm -f /var/lib/keystone/keystone.db

    sleep 8

    # optional of course
    (crontab -l -u keystone 2>&1 | grep -q token_flush) || \
        echo '@hourly /usr/bin/keystone-manage token_flush >/var/log/keystone/keystone-tokenflush.log 2>&1' \
        >> /var/spool/cron/crontabs/keystone

    # Create admin token
    if [ $OSVERSION -lt $OSKILO ]; then
	export OS_SERVICE_TOKEN=$ADMIN_TOKEN
	export OS_SERVICE_ENDPOINT=http://$CONTROLLER:35357/$KAPISTR
    else
	export OS_TOKEN=$ADMIN_TOKEN
	export OS_URL=http://$CONTROLLER:35357/$KAPISTR

	if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
	    export OS_IDENTITY_API_VERSION=3
	else
	    export OS_IDENTITY_API_VERSION=2.0
	fi
    fi

    if [ $OSVERSION -lt $OSKILO ]; then
        # Create the service tenant:
	keystone tenant-create --name service --description "Service Tenant"
        # Create the service entity for the Identity service:
	keystone service-create --name keystone --type identity \
            --description "OpenStack Identity Service"
        # Create the API endpoint for the Identity service:
	keystone endpoint-create \
            --service-id `keystone service-list | awk '/ identity / {print $2}'` \
            --publicurl http://$CONTROLLER:5000/v2.0 \
            --internalurl http://$CONTROLLER:5000/v2.0 \
            --adminurl http://$CONTROLLER:35357/v2.0 \
            --region $REGION
    else
	__openstack service create \
	    --name keystone --description "OpenStack Identity" identity

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://${CONTROLLER}:5000/${KAPISTR} \
		--internalurl http://${CONTROLLER}:5000/${KAPISTR} \
		--adminurl http://${CONTROLLER}:35357/${KAPISTR} \
		--region $REGION identity
	else
	    __openstack endpoint create --region $REGION \
		identity public http://${CONTROLLER}:5000/${KAPISTR}
	    __openstack endpoint create --region $REGION \
		identity internal http://${CONTROLLER}:5000/${KAPISTR}
	    __openstack endpoint create --region $REGION \
		identity admin http://${CONTROLLER}:35357/${KAPISTR}
	fi
    fi

    if [ "x${ADMIN_PASS}" = "x" ]; then
        # Create the admin user -- temporarily use the random one for
        # ${ADMIN_API}; we change it right away below manually via sql
	APSWD="${ADMIN_API_PASS}"
    else
	APSWD="${ADMIN_PASS}"
    fi

    if [ $OSVERSION -eq $OSJUNO ]; then
        # Create the admin tenant
	keystone tenant-create --name admin --description "Admin Tenant"
	keystone user-create --name admin --pass "${APSWD}" \
	    --email "${SWAPPER_EMAIL}"
        # Create the admin role
	keystone role-create --name admin
        # Add the admin tenant and user to the admin role:
	keystone user-role-add --tenant admin --user admin --role admin
        # Create the _member_ role:
	keystone role-create --name _member_
        # Add the admin tenant and user to the _member_ role:
	keystone user-role-add --tenant admin --user admin --role _member_

        # Create the adminapi user
	keystone user-create --name ${ADMIN_API} --pass ${ADMIN_API_PASS} \
	    --email "${SWAPPER_EMAIL}"
	keystone user-role-add --tenant admin --user ${ADMIN_API} --role admin
	keystone user-role-add --tenant admin --user ${ADMIN_API} --role _member_
    else
	if [ $OSVERSION -ge $OSMITAKA ]; then
	    openstack domain create --description "Default Domain" default
	fi

	__openstack project create $DOMARG --description "Admin Project" admin
	__openstack user create $DOMARG --password "${APSWD}" \
	    --email "${SWAPPER_EMAIL}" admin
	__openstack role create admin
	__openstack role add --project admin --user admin admin

	__openstack role create user
	__openstack role add --project admin --user admin user

	__openstack project create $DOMARG --description "Service Project" service

        # Create the adminapi user
	__openstack user create $DOMARG --password ${ADMIN_API_PASS} \
	    --email "${SWAPPER_EMAIL}" ${ADMIN_API}
	__openstack role add --project admin --user ${ADMIN_API} admin
	__openstack role add --project admin --user ${ADMIN_API} user
    fi


    if [ "x${ADMIN_PASS}" = "x" ]; then
        #
        # Update the admin user with the passwd hash from our config
        #
	echo "update user set password='${ADMIN_PASS_HASH}' where name='admin'" \
	    | mysql -u root --password=${DB_ROOT_PASS} keystone
    fi

    if [ $OSVERSION -lt $OSKILO ]; then
	unset OS_SERVICE_TOKEN OS_SERVICE_ENDPOINT
    else
	unset OS_TOKEN OS_URL
	unset OS_IDENTITY_API_VERSION
    fi

    crudini --del /etc/keystone/keystone.conf DEFAULT admin_token

    # Save the passwd
    echo "ADMIN_API=\"${ADMIN_API}\"" >> $SETTINGS
    echo "ADMIN_API_PASS=\"${ADMIN_API_PASS}\"" >> $SETTINGS
    echo "KEYSTONE_DBPASS=\"${KEYSTONE_DBPASS}\"" >> $SETTINGS

    logtend "keystone"
fi

#
# Create the admin-openrc.{sh,py} files.
#
echo "export OS_TENANT_NAME=admin" > $OURDIR/admin-openrc-oldcli.sh
echo "export OS_USERNAME=${ADMIN_API}" >> $OURDIR/admin-openrc-oldcli.sh
echo "export OS_PASSWORD=${ADMIN_API_PASS}" >> $OURDIR/admin-openrc-oldcli.sh
echo "export OS_AUTH_URL=http://$CONTROLLER:35357/v2.0" >> $OURDIR/admin-openrc-oldcli.sh

echo "OS_TENANT_NAME=\"admin\"" > $OURDIR/admin-openrc-oldcli.py
echo "OS_USERNAME=\"${ADMIN_API}\"" >> $OURDIR/admin-openrc-oldcli.py
echo "OS_PASSWORD=\"${ADMIN_API_PASS}\"" >> $OURDIR/admin-openrc-oldcli.py
echo "OS_AUTH_URL=\"http://$CONTROLLER:35357/v2.0\"" >> $OURDIR/admin-openrc-oldcli.py
if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
    echo "OS_IDENTITY_API_VERSION=3" >> $OURDIR/admin-openrc-oldcli.py
else
    echo "OS_IDENTITY_API_VERSION=2.0" >> $OURDIR/admin-openrc-oldcli.py
fi

#
# These trigger a bug with the openstack client -- it doesn't choose v2.0
# if they're set.
#
if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
    if [ $OSVERSION -lt $OSMITAKA ]; then
	echo "export OS_PROJECT_DOMAIN_ID=default" > $OURDIR/admin-openrc-newcli.sh
	echo "export OS_USER_DOMAIN_ID=default" >> $OURDIR/admin-openrc-newcli.sh
    else
	echo "export OS_PROJECT_DOMAIN_NAME=default" > $OURDIR/admin-openrc-newcli.sh
	echo "export OS_USER_DOMAIN_NAME=default" >> $OURDIR/admin-openrc-newcli.sh
    fi
fi
echo "export OS_PROJECT_NAME=admin" >> $OURDIR/admin-openrc-newcli.sh
echo "export OS_TENANT_NAME=admin" >> $OURDIR/admin-openrc-newcli.sh
echo "export OS_USERNAME=${ADMIN_API}" >> $OURDIR/admin-openrc-newcli.sh
echo "export OS_PASSWORD=${ADMIN_API_PASS}" >> $OURDIR/admin-openrc-newcli.sh
echo "export OS_AUTH_URL=http://$CONTROLLER:35357/${KAPISTR}" >> $OURDIR/admin-openrc-newcli.sh
if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
    echo "export OS_IDENTITY_API_VERSION=3" >> $OURDIR/admin-openrc-newcli.sh
else
    echo "export OS_IDENTITY_API_VERSION=2.0" >> $OURDIR/admin-openrc-newcli.sh
fi
if [ $OSVERSION -ge $OSNEWTON ]; then
    echo "export OS_IMAGE_API_VERSION=2" >> $OURDIR/admin-openrc-newcli.sh
fi

if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
    if [ $OSVERSION -lt $OSMITAKA ]; then
	echo "OS_PROJECT_DOMAIN_ID=\"default\"" > $OURDIR/admin-openrc-newcli.py
	echo "OS_USER_DOMAIN_ID=\"default\"" >> $OURDIR/admin-openrc-newcli.py
    else
	echo "OS_PROJECT_DOMAIN_NAME=\"default\"" > $OURDIR/admin-openrc-newcli.py
	echo "OS_USER_DOMAIN_NAME=\"default\"" >> $OURDIR/admin-openrc-newcli.py
    fi
fi
echo "OS_PROJECT_NAME=\"admin\"" >> $OURDIR/admin-openrc-newcli.py
echo "OS_TENANT_NAME=\"admin\"" >> $OURDIR/admin-openrc-newcli.py
echo "OS_USERNAME=\"${ADMIN_API}\"" >> $OURDIR/admin-openrc-newcli.py
echo "OS_PASSWORD=\"${ADMIN_API_PASS}\"" >> $OURDIR/admin-openrc-newcli.py
echo "OS_AUTH_URL=\"http://$CONTROLLER:35357/${KAPISTR}\"" >> $OURDIR/admin-openrc-newcli.py
if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
    echo "OS_IDENTITY_API_VERSION=3" >> $OURDIR/admin-openrc-newcli.py
else
    echo "OS_IDENTITY_API_VERSION=2.0" >> $OURDIR/admin-openrc-newcli.py
fi
if [ $OSVERSION -ge $OSNEWTON ]; then
    echo "OS_IMAGE_API_VERSION=2" >> $OURDIR/admin-openrc-newcli.py
fi

#
# From here on out, we need to be the adminapi user.
#
if [ $OSVERSION -eq $OSJUNO ]; then
    export OS_TENANT_NAME=admin
    export OS_USERNAME=${ADMIN_API}
    export OS_PASSWORD=${ADMIN_API_PASS}
    export OS_AUTH_URL=http://$CONTROLLER:35357/${KAPISTR}

    ln -sf $OURDIR/admin-openrc-oldcli.sh $OURDIR/admin-openrc.sh
    ln -sf $OURDIR/admin-openrc-oldcli.py $OURDIR/admin-openrc.py
else
    if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
	if [ $OSVERSION -lt $OSMITAKA ]; then
	    export OS_PROJECT_DOMAIN_ID=default
	    export OS_USER_DOMAIN_ID=default
	else
	    export OS_PROJECT_DOMAIN_NAME=default
	    export OS_USER_DOMAIN_NAME=default
	fi
    fi
    export OS_PROJECT_NAME=admin
    export OS_TENANT_NAME=admin
    export OS_USERNAME=${ADMIN_API}
    export OS_PASSWORD=${ADMIN_API_PASS}
    export OS_AUTH_URL=http://${CONTROLLER}:35357/${KAPISTR}
    if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
	export OS_IDENTITY_API_VERSION=3
    else
	export OS_IDENTITY_API_VERSION=2.0
    fi

    ln -sf $OURDIR/admin-openrc-newcli.sh $OURDIR/admin-openrc.sh
    ln -sf $OURDIR/admin-openrc-newcli.py $OURDIR/admin-openrc.py
fi

#
# Install the Image service
#
if [ -z "${GLANCE_DBPASS}" ]; then
    logtstart "glance"
    GLANCE_DBPASS=`$PSWDGEN`
    GLANCE_PASS=`$PSWDGEN`

    echo "create database glance" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on glance.* to 'glance'@'localhost' identified by '$GLANCE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on glance.* to 'glance'@'%' identified by '$GLANCE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    if [ $OSVERSION -lt $OSKILO ]; then
	keystone user-create --name glance --pass $GLANCE_PASS
	keystone user-role-add --user glance --tenant service --role admin
	keystone service-create --name glance --type image \
	    --description "OpenStack Image Service"

	keystone endpoint-create \
	    --service-id `keystone service-list | awk '/ image / {print $2}'` \
	    --publicurl http://$CONTROLLER:9292 \
	    --internalurl http://$CONTROLLER:9292 \
	    --adminurl http://$CONTROLLER:9292 \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $GLANCE_PASS glance
	__openstack role add --user glance --project service admin
	__openstack service create --name glance \
	    --description "OpenStack Image Service" image

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://$CONTROLLER:9292 \
		--internalurl http://$CONTROLLER:9292 \
		--adminurl http://$CONTROLLER:9292 \
		--region $REGION image
	else
	    __openstack endpoint create --region $REGION \
		image public http://$CONTROLLER:9292
	    __openstack endpoint create --region $REGION \
		image internal http://$CONTROLLER:9292
	    __openstack endpoint create --region $REGION \
		image admin http://$CONTROLLER:9292
	fi
    fi

    maybe_install_packages glance python-glanceclient

    crudini --set /etc/glance/glance-api.conf database connection \
	"${DBDSTRING}://glance:${GLANCE_DBPASS}@$CONTROLLER/glance"
    crudini --set /etc/glance/glance-api.conf DEFAULT auth_strategy keystone
    crudini --set /etc/glance/glance-api.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/glance/glance-api.conf DEFAULT debug ${DEBUG_LOGGING}
    crudini --set /etc/glance/glance-api.conf paste_deploy flavor keystone

    if [ $OSVERSION -eq $OSJUNO ]; then
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    identity_uri http://${CONTROLLER}:35357
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    admin_tenant_name service
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    admin_user glance
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    admin_password "${GLANCE_PASS}"
    else
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    ${AUTH_TYPE_PARAM} password
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    ${PROJECT_DOMAIN_PARAM} default
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    ${USER_DOMAIN_PARAM} default
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    project_name service
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    username glance
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    password "${GLANCE_PASS}"
	crudini --set /etc/glance/glance-api.conf glance_store default_store file
	crudini --set /etc/glance/glance-api.conf glance_store \
	    filesystem_store_datadir /var/lib/glance/images/
	#crudini --set /etc/glance/glance-api.conf DEFAULT notification_driver noop
	if [ $OSVERSION -ge $OSNEWTON ]; then
	    crudini --set /etc/glance/glance-api.conf glance_store stores file,http
	fi
    fi
    if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	crudini --set /etc/glance/glance-api.conf keystone_authtoken \
	    memcached_servers ${CONTROLLER}:11211
    fi

    crudini --set /etc/glance/glance-registry.conf database \
	connection "${DBDSTRING}://glance:${GLANCE_DBPASS}@$CONTROLLER/glance"
    crudini --set /etc/glance/glance-registry.conf DEFAULT auth_strategy keystone
    crudini --set /etc/glance/glance-registry.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/glance/glance-registry.conf DEFAULT debug ${DEBUG_LOGGING}
    crudini --set /etc/glance/glance-registry.conf paste_deploy flavor keystone

    if [ $OSVERSION -eq $OSJUNO ]; then
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    identity_uri http://${CONTROLLER}:35357
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    admin_tenant_name service
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    admin_user glance
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    admin_password "${GLANCE_PASS}"
    else
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    ${AUTH_TYPE_PARAM} password
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    ${PROJECT_DOMAIN_PARAM} default
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    ${USER_DOMAIN_PARAM} default
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    project_name service
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    username glance
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    password "${GLANCE_PASS}"
	#crudini --set /etc/glance/glance-registry.conf DEFAULT notification_driver noop
    fi
    if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken \
	    memcached_servers ${CONTROLLER}:11211
    fi

    su -s /bin/sh -c "/usr/bin/glance-manage db_sync" glance

    service_restart glance-registry
    service_enable glance-registry
    service_restart glance-api
    service_enable glance-api
    rm -f /var/lib/glance/glance.sqlite

    echo "GLANCE_DBPASS=\"${GLANCE_DBPASS}\"" >> $SETTINGS
    echo "GLANCE_PASS=\"${GLANCE_PASS}\"" >> $SETTINGS

    logtend "glance"
fi

#
# Install the Compute service on the controller
#
if [ -z "${NOVA_DBPASS}" ]; then
    logtstart "nova"
    NOVA_DBPASS=`$PSWDGEN`
    NOVA_PASS=`$PSWDGEN`

    # Make sure we're consistent with the clients
    maybe_install_packages nova-api

    echo "create database nova" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on nova.* to 'nova'@'localhost' identified by '$NOVA_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on nova.* to 'nova'@'%' identified by '$NOVA_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    if [ $OSVERSION -ge $OSMITAKA ]; then
	echo "create database nova_api" | mysql -u root --password="$DB_ROOT_PASS"
	echo "grant all privileges on nova_api.* to 'nova'@'localhost' identified by '$NOVA_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
	echo "grant all privileges on nova_api.* to 'nova'@'%' identified by '$NOVA_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    fi

    if [ $OSVERSION -ge $OSOCATA ]; then
	echo "create database nova_cell0" | mysql -u root --password="$DB_ROOT_PASS"
	echo "grant all privileges on nova_cell0.* to 'nova'@'localhost' identified by '$NOVA_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
	echo "grant all privileges on nova_cell0.* to 'nova'@'%' identified by '$NOVA_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    fi

    if [ $OSVERSION -eq $OSJUNO ]; then
	keystone user-create --name nova --pass $NOVA_PASS
	keystone user-role-add --user nova --tenant service --role admin
	keystone service-create --name nova --type compute \
	    --description "OpenStack Compute Service"
	keystone endpoint-create \
	    --service-id `keystone service-list | awk '/ compute / {print $2}'` \
	    --publicurl http://$CONTROLLER:8774/v2/%\(tenant_id\)s \
	    --internalurl http://$CONTROLLER:8774/v2/%\(tenant_id\)s \
	    --adminurl http://$CONTROLLER:8774/v2/%\(tenant_id\)s \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $NOVA_PASS nova
	__openstack role add --user nova --project service admin
	__openstack service create --name nova \
	    --description "OpenStack Compute Service" compute

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://$CONTROLLER:8774/${NAPISTR}/%\(tenant_id\)s \
		--internalurl http://$CONTROLLER:8774/${NAPISTR}/%\(tenant_id\)s \
		--adminurl http://$CONTROLLER:8774/${NAPISTR}/%\(tenant_id\)s \
		--region $REGION compute
	elif [ $OSVERSION -lt $OSNEWTON ]; then
	    __openstack endpoint create --region $REGION \
		compute public http://${CONTROLLER}:8774/${NAPISTR}/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		compute internal http://${CONTROLLER}:8774/${NAPISTR}/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		compute admin http://${CONTROLLER}:8774/${NAPISTR}/%\(tenant_id\)s
	else
	    __openstack endpoint create --region $REGION \
		compute public http://${CONTROLLER}:8774/${NAPISTR}
	    __openstack endpoint create --region $REGION \
		compute internal http://${CONTROLLER}:8774/${NAPISTR}
	    __openstack endpoint create --region $REGION \
		compute admin http://${CONTROLLER}:8774/${NAPISTR}
	fi

	if [ $OSVERSION -ge $OSOCATA ]; then
	    PLACEMENT_PASS=`$PSWDGEN`
	    __openstack user create $DOMARG --password $PLACEMENT_PASS placement
	    __openstack role add --user placement --project service admin
	    __openstack service create --name placement \
	        --description "OpenStack Placement API" placement

	    __openstack endpoint create --region $REGION \
		placement public http://${CONTROLLER}:8778
	    __openstack endpoint create --region $REGION \
		placement internal http://${CONTROLLER}:8778
	    __openstack endpoint create --region $REGION \
		placement admin http://${CONTROLLER}:8778
	fi
    fi

    maybe_install_packages nova-api nova-conductor nova-consoleauth \
	nova-novncproxy nova-scheduler python-novaclient
    maybe_install_packages nova-cert
    if [ $OSVERSION -ge $OSOCATA ]; then
	maybe_install_packages nova-placement-api
    fi
    
    if [ ${ENABLE_NEW_SERIAL_SUPPORT} = 1 ]; then
	maybe_install_packages nova-serialproxy
	mkdir -p $OURDIR/src
	( cd $OURDIR/src && git clone https://github.com/larsks/novaconsole )
	( cd $OURDIR/src && git clone https://github.com/liris/websocket-client )
	cat <<EOF > $OURDIR/novaconsole.sh
#!/bin/sh
source $OURDIR/admin-openrc.sh
export PYTHONPATH=$OURDIR/src/websocket-client:$OURDIR/src/novaconsole
exec $OURDIR/src/novaconsole/novaconsole/main.py $@
EOF
	chmod ug+x $OURDIR/novaconsole.sh
    fi

    # XXX: Liberty/Mitaka must have lost ec2 stuff by default?
    if [ $OSVERSION -ge $OSLIBERTY ]; then
	crudini --set /etc/nova/nova.conf \
	    DEFAULT enabled_apis osapi_compute,metadata
    fi

    crudini --set /etc/nova/nova.conf database connection \
	"${DBDSTRING}://nova:$NOVA_DBPASS@$CONTROLLER/nova"
    if [ $OSVERSION -ge $OSMITAKA ]; then
	crudini --set /etc/nova/nova.conf api_database connection \
	    "${DBDSTRING}://nova:$NOVA_DBPASS@$CONTROLLER/nova_api"
    fi
    crudini --set /etc/nova/nova.conf DEFAULT auth_strategy keystone
    crudini --set /etc/nova/nova.conf DEFAULT my_ip ${MGMTIP}
    if [ $OSVERSION -lt $OSMITAKA ]; then
	crudini --set /etc/nova/nova.conf glance host $CONTROLLER
    else
	crudini --set /etc/nova/nova.conf \
	    glance api_servers http://${CONTROLLER}:9292
    fi
    crudini --set /etc/nova/nova.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/nova/nova.conf DEFAULT debug ${DEBUG_LOGGING}

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/nova/nova.conf DEFAULT rpc_backend rabbit
	crudini --set /etc/nova/nova.conf DEFAULT rabbit_host $CONTROLLER
	crudini --set /etc/nova/nova.conf DEFAULT rabbit_userid ${RABBIT_USER}
	crudini --set /etc/nova/nova.conf DEFAULT rabbit_password "${RABBIT_PASS}"
    elif [ $OSVERSION -lt $OSNEWTON ]; then
	crudini --set /etc/nova/nova.conf DEFAULT rpc_backend rabbit
	crudini --set /etc/nova/nova.conf oslo_messaging_rabbit \
	    rabbit_host $CONTROLLER
	crudini --set /etc/nova/nova.conf oslo_messaging_rabbit \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/nova/nova.conf oslo_messaging_rabbit \
	    rabbit_password "${RABBIT_PASS}"
    else
	crudini --set /etc/nova/nova.conf DEFAULT transport_url $RABBIT_URL
    fi

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    identity_uri http://${CONTROLLER}:35357
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    admin_tenant_name service
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    admin_user nova
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    admin_password "${NOVA_PASS}"
    else
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    ${AUTH_TYPE_PARAM} password
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    ${PROJECT_DOMAIN_PARAM} default
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    ${USER_DOMAIN_PARAM} default
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    project_name service
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    username nova
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    password "${NOVA_PASS}"
    fi

    if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	crudini --set /etc/nova/nova.conf keystone_authtoken \
	    memcached_servers ${CONTROLLER}:11211
    fi

    if [ $OSVERSION -ge $OSMITAKA ]; then
	crudini --set /etc/nova/nova.conf DEFAULT use_neutron True
	crudini --set /etc/nova/nova.conf \
	    DEFAULT firewall_driver nova.virt.firewall.NoopFirewallDriver
    fi

    if [ $OSVERSION -lt $OSLIBERTY ]; then
	crudini --set /etc/nova/nova.conf DEFAULT vncserver_listen ${MGMTIP}
	crudini --set /etc/nova/nova.conf DEFAULT vncserver_proxyclient_address ${MGMTIP}
    else
	crudini --set /etc/nova/nova.conf vnc vncserver_listen ${MGMTIP}
	crudini --set /etc/nova/nova.conf vnc vncserver_proxyclient_address ${MGMTIP}
    fi

    #
    # Apparently on Kilo and before, the default filters did not include
    # DiskFilter, but in Liberty it does.  This causes us problems for
    # our small root partition :).
    #
    if [ $OSVERSION -eq $OSKILO ]; then
	crudini --set /etc/nova/nova.conf DEFAULT scheduler_available_filters \
	    nova.scheduler.filters.all_filters
	crudini --set /etc/nova/nova.conf DEFAULT scheduler_default_filters \
	    'RetryFilter, AvailabilityZoneFilter, RamFilter, ComputeFilter, ComputeCapabilitiesFilter, ImagePropertiesFilter, ServerGroupAntiAffinityFilter, ServerGroupAffinityFilter'
    elif [ $OSVERSION -ge $OSLIBERTY -a $OSVERSION -lt $OSOCATA ]; then
	crudini --set /etc/nova/nova.conf DEFAULT scheduler_available_filters \
	    nova.scheduler.filters.all_filters
	crudini --set /etc/nova/nova.conf DEFAULT scheduler_default_filters \
	    'RetryFilter, AvailabilityZoneFilter, RamFilter, ComputeFilter, ComputeCapabilitiesFilter, ImagePropertiesFilter, ServerGroupAntiAffinityFilter, ServerGroupAffinityFilter'
    elif [ $OSVERSION -ge $OSOCATA ]; then
	crudini --set /etc/nova/nova.conf filter_scheduler available_filters \
	    nova.scheduler.filters.all_filters
	crudini --set /etc/nova/nova.conf filter_scheduler enabled_filters \
	    'RetryFilter, AvailabilityZoneFilter, RamFilter, ComputeFilter, ComputeCapabilitiesFilter, ImagePropertiesFilter, ServerGroupAntiAffinityFilter, ServerGroupAffinityFilter'
    fi

    if [ $OSVERSION -ge $OSKILO ]; then
	crudini --set /etc/nova/nova.conf oslo_concurrency \
	    lock_path /var/lib/nova/tmp
    fi

    if [ ${ENABLE_NEW_SERIAL_SUPPORT} = 1 ]; then
	crudini --set /etc/nova/nova.conf serial_console enabled true
    fi

    if [ $OSVERSION -ge $OSLIBERTY ]; then
	# Doc bug: these are supposed to be not just a large amount;
	# they should be set to the same number as api_workers, and that
	# defaults to the number of CPUs in the system.
	# This can manifest under heavy load as a bug.
	ncpus=`cat /proc/cpuinfo | grep -i 'processor.*:' | wc -l`
	crudini --set /etc/nova/nova.conf api_database max_overflow $ncpus
	crudini --set /etc/nova/nova.conf api_database max_pool_size $ncpus
    fi

    if [ $OSVERSION -ge $OSOCATA ]; then
	crudini --set /etc/nova/nova.conf placement \
	    os_region_name $REGION
	crudini --set /etc/nova/nova.conf placement \
	    auth_url http://${CONTROLLER}:35357/v3
	crudini --set /etc/nova/nova.conf placement \
	    ${AUTH_TYPE_PARAM} password
	crudini --set /etc/nova/nova.conf placement \
	    ${PROJECT_DOMAIN_PARAM} default
	crudini --set /etc/nova/nova.conf placement \
	    ${USER_DOMAIN_PARAM} default
	crudini --set /etc/nova/nova.conf placement \
	    project_name service
	crudini --set /etc/nova/nova.conf placement \
	    username placement
	crudini --set /etc/nova/nova.conf placement \
	    password "${PLACEMENT_PASS}"
    fi

    if [ $OSVERSION -ge $OSMITAKA ]; then
	su -s /bin/sh -c "nova-manage api_db sync" nova
    fi
    if [ $OSVERSION -ge $OSOCATA ]; then
	su -s /bin/sh -c "nova-manage cell_v2 map_cell0" nova
	su -s /bin/sh -c "nova-manage cell_v2 create_cell --name=cell1 --verbose" nova
    fi
    su -s /bin/sh -c "nova-manage db sync" nova

    service_restart memcached
    service_restart nova-api
    service_enable nova-api
    service_restart nova-cert
    service_enable nova-cert
    service_restart nova-consoleauth
    service_enable nova-consoleauth
    service_restart nova-scheduler
    service_enable nova-scheduler
    service_restart nova-conductor
    service_enable nova-conductor
    service_restart nova-novncproxy
    service_enable nova-novncproxy
    service_restart nova-serialproxy
    service_enable nova-serialproxy
    if [ $OSVERSION -ge $OSOCATA ]; then
	a2ensite nova-placement-api.conf
	service_restart apache2
    else
	service_restart nova-placement-api
	service_enable nova-placement-api
    fi

    rm -f /var/lib/nova/nova.sqlite

    #
    # Ensure that the default flavors exist.  They seem not to on Newton...
    #
    /usr/bin/openstack flavor show m1.tiny 2>&1 >/dev/null
    if [ ! $? -eq 0 ]; then
	__openstack flavor create m1.tiny --id 1 --ram 512 --disk 1 --vcpus 1 --public
    fi
    /usr/bin/openstack flavor show m1.small 2>&1 >/dev/null
    if [ ! $? -eq 0 ]; then
	__openstack flavor create m1.small --id 2 --ram 2048 --disk 20 --vcpus 1 --public
    fi
    /usr/bin/openstack flavor show m1.medium 2>&1 >/dev/null
    if [ ! $? -eq 0 ]; then
	__openstack flavor create m1.medium --id 3 --ram 4096 --disk 40 --vcpus 2 --public
    fi
    /usr/bin/openstack flavor show m1.large 2>&1 >/dev/null
    if [ ! $? -eq 0 ]; then
	__openstack flavor create m1.large --id 4 --ram 8192 --disk 80 --vcpus 4 --public
    fi
    /usr/bin/openstack flavor show m1.xlarge 2>&1 >/dev/null
    if [ ! $? -eq 0 ]; then
	__openstack flavor create m1.xlarge --id 5 --ram 16384 --disk 160 --vcpus 8 --public
    fi

    echo "NOVA_DBPASS=\"${NOVA_DBPASS}\"" >> $SETTINGS
    echo "NOVA_PASS=\"${NOVA_PASS}\"" >> $SETTINGS
    echo "PLACEMENT_PASS=\"${PLACEMENT_PASS}\"" >> $SETTINGS
    logtend "nova"
fi

#
# Install the Compute service on the compute nodes
#
PHOSTS=""
mkdir -p $OURDIR/pssh.setup-compute.stdout $OURDIR/pssh.setup-compute.stderr

if [ -z "${NOVA_COMPUTENODES_DONE}" ]; then
    logtstart "nova-computenodes"
    NOVA_COMPUTENODES_DONE=1

    for node in $COMPUTENODES
    do
	fqdn=`getfqdn $node`

	# Copy the latest settings (passwords, endpoints, whatever) over
	scp -o StrictHostKeyChecking=no $SETTINGS admin-openrc.sh $fqdn:$OURDIR

	PHOSTS="$PHOSTS -H $fqdn"
    done

    echo "*** Setting up Cmopute service on nodes: $PHOSTS"
    $PSSH $PHOSTS -o $OURDIR/pssh.setup-compute.stdout \
	-e $OURDIR/pssh.setup-compute.stderr $DIRNAME/setup-compute.sh

    for node in $COMPUTENODES
    do
	touch $OURDIR/compute-done-${node}
    done

    if [ $OSVERSION -ge $OSOCATA ]; then
	su -s /bin/sh -c "nova-manage cell_v2 discover_hosts --verbose" nova
	crudini --set /etc/nova/nova.conf scheduler discover_hosts_in_cells_interval 300
    fi

    echo "NOVA_COMPUTENODES_DONE=\"${NOVA_COMPUTENODES_DONE}\"" >> $SETTINGS
    logtend "nova-computenodes"
fi

#
# Install the Network service on the controller
#
if [ -z "${NEUTRON_DBPASS}" ]; then
    logtstart "neutron"
    NEUTRON_DBPASS=`$PSWDGEN`
    NEUTRON_PASS=`$PSWDGEN`
    NEUTRON_METADATA_SECRET=`$PSWDGEN`

    . $OURDIR/neutron.vars

    echo "create database neutron" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on neutron.* to 'neutron'@'localhost' identified by '$NEUTRON_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on neutron.* to 'neutron'@'%' identified by '$NEUTRON_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    if [ $OSVERSION -eq $OSJUNO ]; then
	keystone user-create --name neutron --pass ${NEUTRON_PASS}
	keystone user-role-add --user neutron --tenant service --role admin

	keystone service-create --name neutron --type network \
	    --description "OpenStack Networking Service"

	keystone endpoint-create \
	    --service-id `keystone service-list | awk '/ network / {print $2}'` \
	    --publicurl http://$CONTROLLER:9696 \
	    --adminurl http://$CONTROLLER:9696 \
	    --internalurl http://$CONTROLLER:9696 \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $NEUTRON_PASS neutron
	__openstack role add --user neutron --project service admin
	__openstack service create --name neutron \
	    --description "OpenStack Networking Service" network

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://${CONTROLLER}:9696 \
		--adminurl http://${CONTROLLER}:9696 \
		--internalurl http://${CONTROLLER}:9696 \
		--region $REGION network
	else
	    __openstack endpoint create --region $REGION \
		network public http://${CONTROLLER}:9696
	    __openstack endpoint create --region $REGION \
		network internal http://${CONTROLLER}:9696
	    __openstack endpoint create --region $REGION \
		network admin http://${CONTROLLER}:9696
	fi
    fi

    maybe_install_packages neutron-server neutron-plugin-ml2 python-neutronclient

    #
    # Install a patch to make manual router interfaces less likely to hijack
    # public addresses.  Ok, forget it, this patch would just have to set the
    # gateway, not create an "internal" interface.
    #
    #if [ ${OSCODENAME} = "kilo" ]; then
    #	patch -d / -p0 < $DIRNAME/etc/neutron-interface-add.patch.patch
    #fi

    crudini --set /etc/neutron/neutron.conf \
	database connection "${DBDSTRING}://neutron:$NEUTRON_DBPASS@$CONTROLLER/neutron"

    crudini --del /etc/neutron/neutron.conf keystone_authtoken auth_host
    crudini --del /etc/neutron/neutron.conf keystone_authtoken auth_port
    crudini --del /etc/neutron/neutron.conf keystone_authtoken auth_protocol

    crudini --set /etc/neutron/neutron.conf DEFAULT auth_strategy keystone
    crudini --set /etc/neutron/neutron.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/neutron/neutron.conf DEFAULT debug ${DEBUG_LOGGING}
    crudini --set /etc/neutron/neutron.conf DEFAULT core_plugin ml2
    crudini --set /etc/neutron/neutron.conf DEFAULT service_plugins 'router,metering'
    crudini --set /etc/neutron/neutron.conf DEFAULT allow_overlapping_ips True

    if [ $OSVERSION -le $OSKILO ]; then
	crudini --set /etc/neutron/neutron.conf DEFAULT my_ip ${MGMTIP}
    fi

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/neutron/neutron.conf DEFAULT rpc_backend rabbit
	crudini --set /etc/neutron/neutron.conf DEFAULT rabbit_host $CONTROLLER
	crudini --set /etc/neutron/neutron.conf DEFAULT rabbit_userid ${RABBIT_USER}
	crudini --set /etc/neutron/neutron.conf DEFAULT rabbit_password "${RABBIT_PASS}"
    elif [ $OSVERSION -lt $OSNEWTON ]; then
	crudini --set /etc/neutron/neutron.conf DEFAULT rpc_backend rabbit
	crudini --set /etc/neutron/neutron.conf oslo_messaging_rabbit \
	    rabbit_host $CONTROLLER
	crudini --set /etc/neutron/neutron.conf oslo_messaging_rabbit \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/neutron/neutron.conf oslo_messaging_rabbit \
	    rabbit_password "${RABBIT_PASS}"
    else
	crudini --set /etc/neutron/neutron.conf DEFAULT transport_url $RABBIT_URL
    fi

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    identity_uri http://${CONTROLLER}:35357
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    admin_tenant_name service
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    admin_user neutron
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    admin_password "${NEUTRON_PASS}"
    else
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    ${AUTH_TYPE_PARAM} password
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    ${PROJECT_DOMAIN_PARAM} default
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    ${USER_DOMAIN_PARAM} default
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    project_name service
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    username neutron
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    password "${NEUTRON_PASS}"
    fi
    if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	crudini --set /etc/neutron/neutron.conf keystone_authtoken \
	    memcached_servers ${CONTROLLER}:11211
    fi

    crudini --set /etc/neutron/neutron.conf DEFAULT \
	notify_nova_on_port_status_changes True
    crudini --set /etc/neutron/neutron.conf DEFAULT \
	notify_nova_on_port_data_changes True
    crudini --set /etc/neutron/neutron.conf DEFAULT \
	nova_url http://$CONTROLLER:8774/${NAPISTR}

    if [ $OSVERSION -eq $OSJUNO ]; then
	service_tenant_id=`keystone tenant-get service | grep id | cut -d '|' -f 3`

	crudini --set /etc/neutron/neutron.conf DEFAULT \
	    nova_admin_auth_url http://$CONTROLLER:35357/${KAPISTR}
	crudini --set /etc/neutron/neutron.conf DEFAULT nova_region_name $REGION
	crudini --set /etc/neutron/neutron.conf DEFAULT nova_admin_username nova
	crudini --set /etc/neutron/neutron.conf DEFAULT \
	    nova_admin_tenant_id ${service_tenant_id}
	crudini --set /etc/neutron/neutron.conf DEFAULT \
	    nova_admin_password ${NOVA_PASS}
    else
	crudini --set /etc/neutron/neutron.conf nova \
	    auth_url http://$CONTROLLER:35357
	crudini --set /etc/neutron/neutron.conf nova ${AUTH_TYPE_PARAM} password
	crudini --set /etc/neutron/neutron.conf nova ${PROJECT_DOMAIN_PARAM} default
	crudini --set /etc/neutron/neutron.conf nova ${USER_DOMAIN_PARAM} default
	crudini --set /etc/neutron/neutron.conf nova region_name $REGION
	crudini --set /etc/neutron/neutron.conf nova project_name service
	crudini --set /etc/neutron/neutron.conf nova username nova
	crudini --set /etc/neutron/neutron.conf nova password ${NOVA_PASS}
    fi
    if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	crudini --set /etc/neutron/neutron.conf nova \
	    memcached_servers ${CONTROLLER}:11211
    fi

    if [ $OSVERSION -lt $OSMITAKA ]; then
	crudini --set /etc/neutron/neutron.conf DEFAULT \
	    notification_driver messagingv2
    else
	crudini --set /etc/neutron/neutron.conf \
	    oslo_messaging_notifications driver messagingv2
    fi
    if [ $OSVERSION -ge $OSLIBERTY ]; then
	# Doc bug: these are supposed to be not just a large amount;
	# they should be set to the same number as api_workers, and that
	# defaults to the number of CPUs in the system.
	# This can manifest under heavy load as a bug.
	ncpus=`cat /proc/cpuinfo | grep -i 'processor.*:' | wc -l`
	crudini --set /etc/neutron/neutron.conf database max_overflow $ncpus
	crudini --set /etc/neutron/neutron.conf database max_pool_size $ncpus
    fi

    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 \
	type_drivers ${network_types}
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 \
	tenant_network_types ${network_types}
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 \
	mechanism_drivers openvswitch
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_flat \
	flat_networks ${flat_networks}
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_gre \
	tunnel_id_ranges 1:1000
cat <<EOF >>/etc/neutron/plugins/ml2/ml2_conf.ini
[ml2_type_vlan]
${network_vlan_ranges}
EOF
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vxlan \
	vni_ranges 3000:4000
#    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vxlan \
#	vxlan_group 224.0.0.1
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup \
	enable_security_group True
    crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup \
	enable_ipset True
    if [ -n "$fwdriver" ]; then
	crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup \
	    firewall_driver $fwdriver
    fi

    crudini --set /etc/nova/nova.conf DEFAULT \
	network_api_class nova.network.neutronv2.api.API
    crudini --set /etc/nova/nova.conf DEFAULT \
	security_group_api neutron
    if [ "${ML2PLUGIN}" = "openvswitch" ]; then
	crudini --set /etc/nova/nova.conf DEFAULT linuxnet_interface_driver \
	    nova.network.linux_net.LinuxOVSInterfaceDriver
    else
	crudini --set /etc/nova/nova.conf DEFAULT linuxnet_interface_driver \
	    nova.network.linux_net.NeutronLinuxBridgeInterfaceDriver
    fi
    crudini --set /etc/nova/nova.conf DEFAULT \
	firewall_driver nova.virt.firewall.NoopFirewallDriver

    crudini --set /etc/nova/nova.conf neutron \
	url http://$CONTROLLER:9696
    crudini --set /etc/nova/nova.conf neutron \
	auth_strategy keystone
    if [ $OSVERSION -le $OSKILO ]; then
	crudini --set /etc/nova/nova.conf neutron \
	    admin_auth_url http://$CONTROLLER:35357/${KAPISTR}
    else
	crudini --set /etc/nova/nova.conf neutron \
	    auth_url http://$CONTROLLER:35357
    fi
    if [ $OSVERSION -lt $OSMITAKA ]; then
	crudini --set /etc/nova/nova.conf neutron \
	    auth_plugin password
	crudini --set /etc/nova/nova.conf neutron \
	    admin_tenant_name service
	crudini --set /etc/nova/nova.conf neutron \
	    admin_username neutron
	crudini --set /etc/nova/nova.conf neutron \
	    admin_password ${NEUTRON_PASS}
	crudini --set /etc/nova/nova.conf neutron \
	    username neutron
	crudini --set /etc/nova/nova.conf neutron \
	    password ${NEUTRON_PASS}
    else
	crudini --set /etc/nova/nova.conf neutron \
	    ${PROJECT_DOMAIN_PARAM} default
	crudini --set /etc/nova/nova.conf neutron \
	    ${USER_DOMAIN_PARAM} default
	crudini --set /etc/nova/nova.conf neutron \
	    auth_type password
	crudini --set /etc/nova/nova.conf neutron \
	    project_name service
	crudini --set /etc/nova/nova.conf neutron \
	    username neutron
	crudini --set /etc/nova/nova.conf neutron \
	    password ${NEUTRON_PASS}
	crudini --set /etc/nova/nova.conf neutron region_name $REGION
    fi
    if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	crudini --set /etc/nova/nova.conf neutron \
	    memcached_servers ${CONTROLLER}:11211
    fi
    crudini --set /etc/nova/nova.conf neutron \
	service_metadata_proxy True
    crudini --set /etc/nova/nova.conf neutron \
	metadata_proxy_shared_secret ${NEUTRON_METADATA_SECRET}

    if [ $OSVERSION -ge $OSNEWTON ]; then
	su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron
    else
	su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade ${OSCODENAME}" neutron
    fi

    service_restart nova-api
    service_restart nova-scheduler
    service_restart nova-conductor
    service_restart neutron-server
    service_enable neutron-server

    echo "NEUTRON_DBPASS=\"${NEUTRON_DBPASS}\"" >> $SETTINGS
    echo "NEUTRON_PASS=\"${NEUTRON_PASS}\"" >> $SETTINGS
    echo "NEUTRON_METADATA_SECRET=\"${NEUTRON_METADATA_SECRET}\"" >> $SETTINGS
    logtend "neutron"
fi

#
# Install the Network service on the networkmanager
#
if [ -z "${NEUTRON_NETWORKMANAGER_DONE}" ]; then
    logtstart "neutron-networkmanager"
    NEUTRON_NETWORKMANAGER_DONE=1

    if ! unified ; then
	echo "*** Setting up separate networkmanager"

	fqdn=`getfqdn $NETWORKMANAGER`

        # Copy the latest settings (passwords, endpoints, whatever) over
	scp -o StrictHostKeyChecking=no $SETTINGS $fqdn:$SETTINGS

	ssh -o StrictHostKeyChecking=no $fqdn \
	    $DIRNAME/setup-networkmanager.sh
    else
	echo "*** Setting up unified networkmanager on controller"
	$DIRNAME/setup-networkmanager.sh
    fi

    echo "NEUTRON_NETWORKMANAGER_DONE=\"${NEUTRON_NETWORKMANAGER_DONE}\"" >> $SETTINGS
    logtend "neutron-networkmanager"
fi

#
# Install the Network service on the compute nodes
#
if [ -z "${NEUTRON_COMPUTENODES_DONE}" ]; then
    logtstart "neutron-computenodes"
    NEUTRON_COMPUTENODES_DONE=1

    PHOSTS=""
    mkdir -p $OURDIR/pssh.setup-compute-network.stdout \
	$OURDIR/pssh.setup-compute-network.stderr

    for node in $COMPUTENODES
    do
	fqdn=`getfqdn $node`

	# Copy the latest settings (passwords, endpoints, whatever) over
	scp -o StrictHostKeyChecking=no $SETTINGS $fqdn:$SETTINGS

	PHOSTS="$PHOSTS -H $fqdn"
    done

    echo "*** Setting up Compute network on nodes: $PHOSTS"
    $PSSH $PHOSTS -o $OURDIR/pssh.setup-compute-network.stdout \
	-e $OURDIR/pssh.setup-compute-network.stderr \
	$DIRNAME/setup-compute-network.sh

    for node in $COMPUTENODES
    do
	touch $OURDIR/compute-network-done-${node}
    done

    # For whatever reason, this makes the linuxbridge plugin happy
    service_restart neutron-server
    # Make sure neutron is alive before continuing
    retries=30
    while [ $retries -gt 0 ]; do
	neutron net-list
	if [ $? -eq 0 ]; then
            break
        else
            sleep 2
            retries=`expr $retries - 1`
        fi
    done

    echo "NEUTRON_COMPUTENODES_DONE=\"${NEUTRON_COMPUTENODES_DONE}\"" >> $SETTINGS
    logtend "neutron-computenodes"
fi

#
# Configure the networks on the controller
#
if [ -z "${NEUTRON_NETWORKS_DONE}" ]; then
    logtstart "neutron-network-ext-float"
    NEUTRON_NETWORKS_DONE=1

    if [ "$OSCODENAME" = "kilo" -o "$OSCODENAME" = "liberty" ]; then
	neutron net-create ext-net --shared --router:external \
	    --provider:physical_network external --provider:network_type flat
    else
	neutron net-create ext-net --shared --router:external True \
	    --provider:physical_network external --provider:network_type flat
    fi

    # Written by setup-(ovs|linuxbridge)-node.sh before changing the
    # default Cloudlab control/expt net config.
    . $OURDIR/ctlnet.vars

    neutron subnet-create ext-net --name ext-subnet \
	--disable-dhcp --gateway $ctlgw $ctlnet

    SID=`neutron subnet-show ext-subnet | awk '/ id / {print $4}'`
    # NB: get rid of the default one!
    if [ ! -z "$SID" ]; then
	echo "delete from ipallocationpools where subnet_id='$SID'" \
	    | mysql --password=${DB_ROOT_PASS} neutron
    fi

    # NB: this is important to do before we connect any routers to the ext-net
    # (i.e., in setup-basic.sh)
    for ip in $PUBLICADDRS ; do
	echo "insert into ipallocationpools values (UUID(),'$SID','$ip','$ip')" \
	    | mysql --password=${DB_ROOT_PASS} neutron
    done

    # Support newer pluggable ipamallocationpools, too.
    if [ $OSVERSION -ge $OSNEWTON ]; then
	IPAMSID=`echo "select id from ipamsubnets where neutron_subnet_id='$SID'" | mysql -N --password=$NEUTRON_DBPASS neutron`
	if [ -z "$IPAMSID" ]; then
	    echo "WARNING: could not find ipamsubnetid from ipamsubnets post-Newton!"
	else
	    echo "delete from ipamallocationpools where ipam_subnet_id='$IPAMSID'" \
		| mysql --password=${DB_ROOT_PASS} neutron
	    for ip in $PUBLICADDRS ; do
		echo "insert into ipamallocationpools values (UUID(),'$IPAMSID','$ip','$ip')" \
		    | mysql --password=${DB_ROOT_PASS} neutron
	    done
	fi
    fi

    echo "NEUTRON_NETWORKS_DONE=\"${NEUTRON_NETWORKS_DONE}\"" >> $SETTINGS
    logtend "neutron-network-ext-float"
fi

#
# Install the Dashboard service on the controller
#
if [ -z "${DASHBOARD_DONE}" ]; then
    logtstart "horizon"
    DASHBOARD_DONE=1

    maybe_install_packages openstack-dashboard apache2 libapache2-mod-wsgi

    sed -i -e "s/OPENSTACK_HOST.*=.*\$/OPENSTACK_HOST = \"${CONTROLLER}\"/" \
	/etc/openstack-dashboard/local_settings.py
    sed -i -e 's/^.*ALLOWED_HOSTS = \[.*$/ALLOWED_HOSTS = \["*"\]/' \
	/etc/openstack-dashboard/local_settings.py

    grep -q SESSION_TIMEOUT /etc/openstack-dashboard/local_settings.py
    if [ $? -eq 0 ]; then
	sed -i -e "s/^.*SESSION_TIMEOUT.*=.*\$/SESSION_TIMEOUT = ${SESSIONTIMEOUT}/" \
	    /etc/openstack-dashboard/local_settings.py
    else
	echo "SESSION_TIMEOUT = ${SESSIONTIMEOUT}" \
	    >> /etc/openstack-dashboard/local_settings.py
    fi

    grep -q OPENSTACK_KEYSTONE_DEFAULT_ROLE /etc/openstack-dashboard/local_settings.py
    if [ $? -eq 0 ]; then
	sed -i -e "s/^.*OPENSTACK_KEYSTONE_DEFAULT_ROLE.*=.*\$/OPENSTACK_KEYSTONE_DEFAULT_ROLE = \"user\"/" \
	    /etc/openstack-dashboard/local_settings.py
    else
	echo "OPENSTACK_KEYSTONE_DEFAULT_ROLE = \"user\"" \
	    >> /etc/openstack-dashboard/local_settings.py
    fi

    if [ $OSVERSION -ge $OSKILO ]; then
	cat <<EOF >> /etc/openstack-dashboard/local_settings.py
CACHES = {
    'default': {
         'BACKEND': 'django.core.cache.backends.memcached.MemcachedCache',
         'LOCATION': '127.0.0.1:11211',
    }
}
EOF
    fi

    if [ $OSVERSION -ge $OSMITAKA ]; then
	cat <<EOF >> /etc/openstack-dashboard/local_settings.py
SESSION_ENGINE = 'django.contrib.sessions.backends.cache'
EOF
    fi

    if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
	IDVERS=3
	grep OPENSTACK_KEYSTONE_URL /etc/openstack-dashboard/local_settings.py
	if [ $? -eq 0 ]; then
	    sed -i -e "s|^.*OPENSTACK_KEYSTONE_URL.*=.*\$|OPENSTACK_KEYSTONE_URL = \"http://%s:5000/v3\" % OPENSTACK_HOST|" \
		/etc/openstack-dashboard/local_settings.py
	else
	    cat <<EOF >> /etc/openstack-dashboard/local_settings.py
OPENSTACK_KEYSTONE_URL = "http://%s:5000/v3" % OPENSTACK_HOST
EOF
	fi
	grep OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT /etc/openstack-dashboard/local_settings.py
	if [ $? -eq 0 ]; then
	    sed -i -e "s|^.*OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT.*=.*\$|OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True|" \
		/etc/openstack-dashboard/local_settings.py
	else
	    cat <<EOF >> /etc/openstack-dashboard/local_settings.py
OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True
EOF
	fi
	grep OPENSTACK_KEYSTONE_DEFAULT_DOMAIN /etc/openstack-dashboard/local_settings.py
	if [ $? -eq 0 ]; then
	    sed -i -e "s|^.*OPENSTACK_KEYSTONE_DEFAULT_DOMAIN.*=.*\$|OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = 'default'|" \
		/etc/openstack-dashboard/local_settings.py
	else
	    cat <<EOF >> /etc/openstack-dashboard/local_settings.py
OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = 'default'
EOF
	fi
    else
	IDVERS=2
    fi
    # Just slap this in :(.
    if [ $OSVERSION -ge $OSMITAKA ]; then
	IMAGEVERS='"image": 2,'
    else
	IMAGEVERS=""
    fi
    cat <<EOF >> /etc/openstack-dashboard/local_settings.py
OPENSTACK_API_VERSIONS = {
    "identity": $IDVERS,
    "volume": 2,
    $IMAGEVERS
}
EOF

    if [ $OSVERSION -ge $OSOCATA ]; then
	chown www-data.www-data /var/lib/openstack-dashboard/secret_key
    fi

    #
    # On some versions, we have special patches to customize horizon.
    # For instance, on Newton, we don't want volume creation to be the
    # default.
    #
    if [ $OSVERSION -eq $OSNEWTON ]; then
	patch -p0 -d / < $DIRNAME/etc/horizon-${OSCODENAME}-no-default-volcreate.patch
	# Rebuild after patching javascripts.
	/usr/share/openstack-dashboard/manage.py collectstatic --noinput \
	    && /usr/share/openstack-dashboard/manage.py compress
    fi

    service_restart apache2
    service_enable apache2
    service_restart memcached

    echo "DASHBOARD_DONE=\"${DASHBOARD_DONE}\"" >> $SETTINGS
    logtend "horizon"
fi

#
# Install some block storage.
#
#if [ 0 -eq 1 -a -z "${CINDER_DBPASS}" ]; then
if [ -z "${CINDER_DBPASS}" ]; then
    logtstart "cinder"
    CINDER_DBPASS=`$PSWDGEN`
    CINDER_PASS=`$PSWDGEN`

    echo "create database cinder" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on cinder.* to 'cinder'@'localhost' identified by '$CINDER_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on cinder.* to 'cinder'@'%' identified by '$CINDER_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    if [ $OSVERSION -eq $OSJUNO ]; then
	keystone user-create --name cinder --pass $CINDER_PASS
	keystone user-role-add --user cinder --tenant service --role admin
	keystone service-create --name cinder --type volume \
	    --description "OpenStack Block Storage Service"
	keystone service-create --name cinderv2 --type volumev2 \
	    --description "OpenStack Block Storage Service"

#    if [ $OSCODENAME = 'juno' ]; then
	keystone endpoint-create \
	    --service-id `keystone service-list | awk '/ volume / {print $2}'` \
	    --publicurl http://${CONTROLLER}:8776/v1/%\(tenant_id\)s \
	    --internalurl http://${CONTROLLER}:8776/v1/%\(tenant_id\)s \
	    --adminurl http://${CONTROLLER}:8776/v1/%\(tenant_id\)s \
	    --region $REGION
#    else
#	# Kilo uses the v2 endpoint even for v1 service
#	keystone endpoint-create \
#	    --service-id `keystone service-list | awk '/ volume / {print $2}'` \
#	    --publicurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
#	    --internalurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
#	    --adminurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
#	    --region $REGION
 #   fi

        keystone endpoint-create \
	    --service-id `keystone service-list | awk '/ volumev2 / {print $2}'` \
	    --publicurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
	    --internalurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
	    --adminurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $CINDER_PASS cinder
	__openstack role add --user cinder --project service admin
	__openstack service create --name cinder \
	    --description "OpenStack Block Storage Service" volume
	__openstack service create --name cinderv2 \
	    --description "OpenStack Block Storage Service" volumev2

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
		--internalurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
		--adminurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
		--region $REGION \
		volume
	    __openstack endpoint create \
		--publicurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
		--internalurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
		--adminurl http://${CONTROLLER}:8776/v2/%\(tenant_id\)s \
		--region $REGION \
		volumev2
	elif [ $OSVERSION -lt $OSOCATA ]; then
	    __openstack endpoint create --region $REGION \
		volume public http://${CONTROLLER}:8776/v1/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		volume internal http://${CONTROLLER}:8776/v1/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		volume admin http://${CONTROLLER}:8776/v1/%\(tenant_id\)s

	    __openstack endpoint create --region $REGION \
		volumev2 public http://${CONTROLLER}:8776/v2/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		volumev2 internal http://${CONTROLLER}:8776/v2/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		volumev2 admin http://${CONTROLLER}:8776/v2/%\(tenant_id\)s
	else
	    __openstack endpoint create --region $REGION \
		volumev2 public http://${CONTROLLER}:8776/v2/%\(project_id\)s
	    __openstack endpoint create --region $REGION \
		volumev2 internal http://${CONTROLLER}:8776/v2/%\(project_id\)s
	    __openstack endpoint create --region $REGION \
		volumev2 admin http://${CONTROLLER}:8776/v2/%\(project_id\)s

	    # Seems like the volumev3 service doesn't exist a priori in
	    # Ocata; create it so these don't fail.
	    openstack service show volumev3 >/dev/null
	    if [ ! $? -eq 0 ]; then
		openstack service create --name volumev3 volumev3
	    fi
	    __openstack endpoint create --region $REGION \
		volumev3 public http://${CONTROLLER}:8776/v3/%\(project_id\)s
	    __openstack endpoint create --region $REGION \
		volumev3 internal http://${CONTROLLER}:8776/v3/%\(project_id\)s
	    __openstack endpoint create --region $REGION \
		volumev3 admin http://${CONTROLLER}:8776/v3/%\(project_id\)s
	fi
    fi

    maybe_install_packages cinder-api cinder-scheduler python-cinderclient

    crudini --set /etc/cinder/cinder.conf \
	database connection "${DBDSTRING}://cinder:$CINDER_DBPASS@$CONTROLLER/cinder"

    crudini --del /etc/cinder/cinder.conf keystone_authtoken auth_host
    crudini --del /etc/cinder/cinder.conf keystone_authtoken auth_port
    crudini --del /etc/cinder/cinder.conf keystone_authtoken auth_protocol

    crudini --set /etc/cinder/cinder.conf DEFAULT auth_strategy keystone
    crudini --set /etc/cinder/cinder.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/cinder/cinder.conf DEFAULT debug ${DEBUG_LOGGING}
    crudini --set /etc/cinder/cinder.conf DEFAULT my_ip ${MGMTIP}

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/cinder/cinder.conf DEFAULT rpc_backend rabbit
	crudini --set /etc/cinder/cinder.conf DEFAULT rabbit_host $CONTROLLER
	crudini --set /etc/cinder/cinder.conf DEFAULT rabbit_userid ${RABBIT_USER}
	crudini --set /etc/cinder/cinder.conf DEFAULT rabbit_password "${RABBIT_PASS}"
    elif [ $OSVERSION -lt $OSNEWTON ]; then
	crudini --set /etc/cinder/cinder.conf DEFAULT rpc_backend rabbit
	crudini --set /etc/cinder/cinder.conf oslo_messaging_rabbit \
	    rabbit_host $CONTROLLER
	crudini --set /etc/cinder/cinder.conf oslo_messaging_rabbit \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/cinder/cinder.conf oslo_messaging_rabbit \
	    rabbit_password "${RABBIT_PASS}"
    else
	crudini --set /etc/cinder/cinder.conf DEFAULT transport_url $RABBIT_URL
    fi

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    identity_uri http://${CONTROLLER}:35357
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    admin_tenant_name service
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    admin_user cinder
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    admin_password "${CINDER_PASS}"
    else
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    ${AUTH_TYPE_PARAM} password
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    ${PROJECT_DOMAIN_PARAM} default
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    ${USER_DOMAIN_PARAM} default
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    project_name service
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    username cinder
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    password "${CINDER_PASS}"
    fi
    if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	crudini --set /etc/cinder/cinder.conf keystone_authtoken \
	    memcached_servers ${CONTROLLER}:11211
    fi

    crudini --set /etc/cinder/cinder.conf DEFAULT glance_host ${CONTROLLER}

    if [ $OSVERSION -eq $OSKILO ]; then
	crudini --set /etc/cinder/cinder.conf oslo_concurrency \
	    lock_path /var/lock/cinder
    elif [ $OSVERSION -ge $OSLIBERTY ]; then
	crudini --set /etc/cinder/cinder.conf oslo_concurrency \
	    lock_path /var/lib/cinder/tmp
    fi

    if [ $OSVERSION -ge $OSLIBERTY ]; then
	crudini --set /etc/nova/nova.conf cinder os_region_name $REGION
    fi

    sed -i -e "s/^\\(.*volume_group.*=.*\\)$/#\1/" /etc/cinder/cinder.conf

    su -s /bin/sh -c "/usr/bin/cinder-manage db sync" cinder

    service_restart cinder-scheduler
    service_enable cinder-scheduler

    if [ $OSVERSION -ge $OSOCATA ]; then
	a2enconf cinder-wsgi.conf
	service_restart apache2
    else
	service_restart cinder-api
	service_enable cinder-api
    fi
    rm -f /var/lib/cinder/cinder.sqlite

    echo "CINDER_DBPASS=\"${CINDER_DBPASS}\"" >> $SETTINGS
    echo "CINDER_PASS=\"${CINDER_PASS}\"" >> $SETTINGS
    logtend "cinder"
fi

if [ -z "${STORAGE_HOST_DONE}" ]; then
    logtstart "cinder-host"
    fqdn=`getfqdn $STORAGEHOST`

    if [ "${STORAGEHOST}" = "${CONTROLLER}" ]; then
	$DIRNAME/setup-storage.sh
    else
        # Copy the latest settings (passwords, endpoints, whatever) over
	scp -o StrictHostKeyChecking=no $SETTINGS $fqdn:$SETTINGS

	ssh -o StrictHostKeyChecking=no $fqdn $DIRNAME/setup-storage.sh
    fi

    echo "STORAGE_HOST_DONE=\"1\"" >> $SETTINGS
    logtend "cinder-host"
fi

#
# Install some shared storage.
#
if [ $OSVERSION -ge $OSMITAKA -a -z "${MANILA_DBPASS}" ]; then
    logtstart "manila"
    MANILA_DBPASS=`$PSWDGEN`
    MANILA_PASS=`$PSWDGEN`

    echo "create database manila" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on manila.* to 'manila'@'localhost' identified by '$MANILA_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on manila.* to 'manila'@'%' identified by '$MANILA_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    __openstack user create $DOMARG --password $MANILA_PASS manila
    __openstack role add --user manila --project service admin
    __openstack service create --name manila \
	--description "OpenStack Shared File Systems" share
    __openstack service create --name manilav2 \
	--description "OpenStack Shared File Systems" sharev2

    if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	__openstack endpoint create \
	    --publicurl http://${CONTROLLER}:8786/v1/%\(tenant_id\)s \
	    --internalurl http://${CONTROLLER}:8786/v1/%\(tenant_id\)s \
	    --adminurl http://${CONTROLLER}:8786/v1/%\(tenant_id\)s \
	    --region $REGION \
	    share
	__openstack endpoint create \
	    --publicurl http://${CONTROLLER}:8786/v2/%\(tenant_id\)s \
	    --internalurl http://${CONTROLLER}:8786/v2/%\(tenant_id\)s \
	    --adminurl http://${CONTROLLER}:8786/v2/%\(tenant_id\)s \
	    --region $REGION \
	    sharev2
    else
	__openstack endpoint create --region $REGION \
	    share public http://${CONTROLLER}:8786/v1/%\(tenant_id\)s
	__openstack endpoint create --region $REGION \
	    share internal http://${CONTROLLER}:8786/v1/%\(tenant_id\)s
	__openstack endpoint create --region $REGION \
	    share admin http://${CONTROLLER}:8786/v1/%\(tenant_id\)s
	
	__openstack endpoint create --region $REGION \
	    sharev2 public http://${CONTROLLER}:8786/v2/%\(tenant_id\)s
	__openstack endpoint create --region $REGION \
	    sharev2 internal http://${CONTROLLER}:8786/v2/%\(tenant_id\)s
	__openstack endpoint create --region $REGION \
	    sharev2 admin http://${CONTROLLER}:8786/v2/%\(tenant_id\)s
    fi

    maybe_install_packages manila-api manila-scheduler python-manilaclient

    crudini --set /etc/manila/manila.conf \
	database connection "${DBDSTRING}://manila:$MANILA_DBPASS@$CONTROLLER/manila"

    crudini --del /etc/manila/manila.conf keystone_authtoken auth_host
    crudini --del /etc/manila/manila.conf keystone_authtoken auth_port
    crudini --del /etc/manila/manila.conf keystone_authtoken auth_protocol

    crudini --set /etc/manila/manila.conf DEFAULT auth_strategy keystone
    crudini --set /etc/manila/manila.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/manila/manila.conf DEFAULT debug ${DEBUG_LOGGING}
    crudini --set /etc/manila/manila.conf DEFAULT my_ip ${MGMTIP}
    crudini --set /etc/manila/manila.conf DEFAULT \
	default_share_type default_share_type
    crudini --set /etc/manila/manila.conf DEFAULT \
	rootwrap_config /etc/manila/rootwrap.conf

    if [ $OSVERSION -lt $OSNEWTON ]; then
	crudini --set /etc/manila/manila.conf DEFAULT rpc_backend rabbit
	crudini --set /etc/manila/manila.conf oslo_messaging_rabbit \
	    rabbit_host $CONTROLLER
	crudini --set /etc/manila/manila.conf oslo_messaging_rabbit \
   	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/manila/manila.conf oslo_messaging_rabbit \
	    rabbit_password "${RABBIT_PASS}"
    else
	crudini --set /etc/manila/manila.conf DEFAULT transport_url $RABBIT_URL
    fi

    crudini --set /etc/manila/manila.conf keystone_authtoken \
	memcached_servers ${CONTROLLER}:11211
    crudini --set /etc/manila/manila.conf keystone_authtoken \
	auth_uri http://${CONTROLLER}:5000
    crudini --set /etc/manila/manila.conf keystone_authtoken \
	auth_url http://${CONTROLLER}:35357
    crudini --set /etc/manila/manila.conf keystone_authtoken \
	${AUTH_TYPE_PARAM} password
    crudini --set /etc/manila/manila.conf keystone_authtoken \
	${PROJECT_DOMAIN_PARAM} default
    crudini --set /etc/manila/manila.conf keystone_authtoken \
	${USER_DOMAIN_PARAM} default
    crudini --set /etc/manila/manila.conf keystone_authtoken \
	project_name service
    crudini --set /etc/manila/manila.conf keystone_authtoken \
	username manila
    crudini --set /etc/manila/manila.conf keystone_authtoken \
	password "${MANILA_PASS}"

    crudini --set /etc/manila/manila.conf oslo_concurrency \
	lock_path /var/lib/manila/tmp

    su -s /bin/sh -c "manila-manage db sync" manila

    # For now, create the default flavor for the service image here.
    # The actual image is downloaded/created in setup-basic-*.sh .
    # It is nice to create it before the daemons run so they don't whine.
    __openstack flavor create manila-service-flavor \
	--id 100 --ram 256 --disk 0 --vcpus 1

    service_restart manila-scheduler
    service_enable manila-scheduler
    service_restart manila-api
    service_enable manila-api
    rm -f /var/lib/manila/manila.sqlite

    # Create the default_share_type we set in manila.conf above.
    manila type-create default_share_type True

    # Note: we create the default share networks in setup-basic.sh

    # Install the UI... complicated by buggy packages.
    maybe_install_packages python-manila-ui
    #
    # The initial mitaka manila-ui package does not include the template
    # files, ugh!
    #
    dpkg-query -L python-manila-ui | grep -q templates
    if [ ! $? -eq 0 ]; then
	if [ ! $DO_APT_UPDATE -eq 0 ]; then
	    # Enable the src repos
	    cp -p /etc/apt/sources.list /etc/apt.sources.list.nosrc
	    sed -i.orig -E -e 's/^ *# *(deb-src.* xenial (universe|main).*)$/\1/' \
		/etc/apt/sources.list
	    sed -i.orig2 -E -e 's/^ *# *(deb-src.* xenial-updates .*)$/\1/' \
		/etc/apt/sources.list
	    apt-get update
	    # Get the source package
	    cwd=`pwd`
	    mkdir -p tmp-python-manila-ui
	    cd tmp-python-manila-ui
	    apt-get source -y python-manila-ui
	    apt-get remove --purge -y python-manila-ui
	    apt-get build-dep -y python-manila-ui
	    srcdir=`find . -maxdepth 1 -type d -name manila-ui-\*`
	    cd $srcdir
	    cat <<EOF >MANIFEST.in
recursive-include manila_ui/dashboards/admin/shares/templates *
recursive-include manila_ui/dashboards/project/shares/templates *
recursive-include manila_ui/dashboards/project/templates *
EOF
	    echo "add manifest for templates" | dpkg-source --auto-commit --commit . add-manifest-templates
	    export DEB_BUILD_OPTIONS=nocheck
	    dpkg-buildpackage -uc
	    cd ..
	    dpkg -i python-manila-ui*.deb
	    # Remove the src repos:
	    sed -i.orig -E -e 's/^(deb-src.*)$/# \1/' /etc/apt/sources.list
	    # Cleanup env
	    unset DEB_BUILD_OPTIONS
	    cd $cwd
	else
	    echo "Error: python-manila-ui does not appear to have templates, but you have requested not to update our Apt cache, so we can't download the source pagckage."
	fi
    fi

    #
    # Ugh, more Manila bugs
    #
    if [ $OSVERSION -eq $OSNEWTON -a -f $DIRNAME/etc/manila-${OSCODENAME}-noset.patch ]; then
	patch -p0 -d / < $DIRNAME/etc/manila-${OSCODENAME}-noset.patch
    fi

    service_restart apache2
    service_restart memcached

    echo "MANILA_DBPASS=\"${MANILA_DBPASS}\"" >> $SETTINGS
    echo "MANILA_PASS=\"${MANILA_PASS}\"" >> $SETTINGS
    logtend "manila"
fi

if [ -z "${SHARE_HOST_DONE}" ]; then
    logtstart "manila-host"
    fqdn=`getfqdn $SHAREHOST`

    if [ "${SHAREHOST}" = "${CONTROLLER}" ]; then
	$DIRNAME/setup-share-node.sh
    else
        # Copy the latest settings (passwords, endpoints, whatever) over
	scp -o StrictHostKeyChecking=no $SETTINGS $fqdn:$SETTINGS

	ssh -o StrictHostKeyChecking=no $fqdn $DIRNAME/setup-share-node.sh
    fi

    echo "SHARE_HOST_DONE=\"1\"" >> $SETTINGS
    logtend "manila-host"
fi

#
# Install some object storage.
#
#if [ 0 -eq 1 -a -z "${SWIFT_DBPASS}" ]; then
if [ -z "${SWIFT_PASS}" ]; then
    logtstart "swift"
    SWIFT_PASS=`$PSWDGEN`
    SWIFT_HASH_PATH_PREFIX=`$PSWDGEN`
    SWIFT_HASH_PATH_SUFFIX=`$PSWDGEN`

    if [ $OSVERSION -eq $OSJUNO ]; then
	keystone user-create --name swift --pass $SWIFT_PASS
	keystone user-role-add --user swift --tenant service --role admin
	keystone service-create --name swift --type object-store \
	    --description "OpenStack Object Storage Service"

	keystone endpoint-create \
	    --service-id `keystone service-list | awk '/ object-store / {print $2}'` \
	    --publicurl http://${CONTROLLER}:8080/v1/AUTH_%\(tenant_id\)s \
	    --internalurl http://${CONTROLLER}:8080/v1/AUTH_%\(tenant_id\)s \
	    --adminurl http://${CONTROLLER}:8080 \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $SWIFT_PASS swift
	__openstack role add --user swift --project service admin
	__openstack service create --name swift \
	    --description "OpenStack Object Storage Service" object-store

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://${CONTROLLER}:8080/v1/AUTH_%\(tenant_id\)s \
		--internalurl http://${CONTROLLER}:8080/v1/AUTH_%\(tenant_id\)s \
		--adminurl http://${CONTROLLER}:8080 \
		--region $REGION \
		object-store
	else
	    __openstack endpoint create --region $REGION \
		object-store public http://${CONTROLLER}:8080/v1/AUTH_%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		object-store internal http://${CONTROLLER}:8080/v1/AUTH_%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		object-store admin http://${CONTROLLER}:8080/v1
	fi
    fi

    maybe_install_packages swift swift-proxy python-swiftclient \
	python-keystoneclient python-keystonemiddleware

    mkdir -p /etc/swift

    wget -O /etc/swift/proxy-server.conf \
	"https://git.openstack.org/cgit/openstack/swift/plain/etc/proxy-server.conf-sample?h=stable/${OSCODENAME}"
    if [ ! $? -eq 0 ]; then
	# Try the EOL version...
	wget -O /etc/swift/proxy-server.conf \
	    "https://git.openstack.org/cgit/openstack/swift/plain/etc/proxy-server.conf-sample?h=${OSCODENAME}-eol"
    fi

    # Just slap these in.
    crudini --set /etc/swift/proxy-server.conf DEFAULT bind_port 8080
    crudini --set /etc/swift/proxy-server.conf DEFAULT user swift
    crudini --set /etc/swift/proxy-server.conf DEFAULT swift_dir /etc/swift

    pipeline=`crudini --get /etc/swift/proxy-server.conf pipeline:main pipeline`
    if [ "$OSCODENAME" = "juno" ]; then
	crudini --set /etc/swift/proxy-server.conf pipeline:main pipeline \
	    'cache authtoken healthcheck keystoneauth proxy-logging proxy-server'
    elif [ $OSVERSION -eq $OSKILO ]; then
	crudini --set /etc/swift/proxy-server.conf pipeline:main pipeline \
	    'catch_errors gatekeeper healthcheck proxy-logging cache container_sync bulk ratelimit authtoken keystoneauth container-quotas account-quotas slo dlo proxy-logging proxy-server'
    else
	crudini --set /etc/swift/proxy-server.conf pipeline:main pipeline \
	    'catch_errors gatekeeper healthcheck proxy-logging cache container_sync bulk ratelimit authtoken keystoneauth container-quotas account-quotas slo dlo versioned_writes proxy-logging proxy-server'
    fi

    crudini --set /etc/swift/proxy-server.conf \
	app:proxy-server use 'egg:swift#proxy'
    crudini --set /etc/swift/proxy-server.conf \
	app:proxy-server allow_account_management true
    crudini --set /etc/swift/proxy-server.conf \
	app:proxy-server account_autocreate true

    crudini --set /etc/swift/proxy-server.conf \
	filter:keystoneauth use 'egg:swift#keystoneauth'
    if [ "$OSCODENAME" = "juno" ]; then
	crudini --set /etc/swift/proxy-server.conf \
	    filter:keystoneauth operator_roles 'admin,_member_'
    else
	crudini --set /etc/swift/proxy-server.conf \
	    filter:keystoneauth operator_roles 'admin,user'
    fi

    crudini --set /etc/swift/proxy-server.conf \
	filter:authtoken paste.filter_factory keystonemiddleware.auth_token:filter_factory
    if [ "$OSCODENAME" = "juno" ]; then
	crudini --set /etc/swift/proxy-server.conf \
	    auth_uri "http://${CONTROLLER}:5000/${KAPISTR}"
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken identity_url "http://${CONTROLLER}:35357"
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken admin_tenant_name service
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken admin_user swift
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken admin_password "${SWIFT_PASS}"
    else
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken auth_uri "http://${CONTROLLER}:5000"
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken auth_url "http://${CONTROLLER}:35357"
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken ${AUTH_TYPE_PARAM} password
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken ${PROJECT_DOMAIN_PARAM} default
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken ${USER_DOMAIN_PARAM} default
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken project_name service
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken username swift
	crudini --set /etc/swift/proxy-server.conf \
	    filter:authtoken password "${SWIFT_PASS}"
    fi
    if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	crudini --set /etc/swift/proxy-server.conf \
	    memcached_servers ${CONTROLLER}:11211
    fi
    crudini --set /etc/swift/proxy-server.conf \
	filter:authtoken delay_auth_decision true

    crudini --set /etc/swift/proxy-server.conf \
	filter:cache use 'egg:swift#memcache'
    crudini --set /etc/swift/proxy-server.conf \
	filter:cache memcache_servers ${CONTROLLER}:11211

    crudini --del /etc/swift/proxy-server.conf keystone_authtoken auth_host
    crudini --del /etc/swift/proxy-server.conf keystone_authtoken auth_port
    crudini --del /etc/swift/proxy-server.conf keystone_authtoken auth_protocol

    mkdir -p /var/log/swift
    chown -R syslog.adm /var/log/swift

    crudini --set /etc/swift/proxy-server.conf DEFAULT log_facility LOG_LOCAL1
    crudini --set /etc/swift/proxy-server.conf DEFAULT log_level INFO
    crudini --set /etc/swift/proxy-server.conf DEFAULT log_name swift-proxy

    echo 'if $programname == "swift-proxy" then { action(type="omfile" file="/var/log/swift/swift-proxy.log") }' >> /etc/rsyslog.d/99-swift.conf

    wget -O /etc/swift/swift.conf \
	"https://git.openstack.org/cgit/openstack/swift/plain/etc/swift.conf-sample?h=stable/${OSCODENAME}"
    if [ ! $? -eq 0 ]; then
	# Try the EOL version...
	wget -O /etc/swift/swift.conf \
	    "https://git.openstack.org/cgit/openstack/swift/plain/etc/swift.conf-sample?h=${OSCODENAME}-eol"
    fi

    crudini --set /etc/swift/swift.conf \
	swift-hash swift_hash_path_suffix "${SWIFT_HASH_PATH_PREFIX}"
    crudini --set /etc/swift/swift.conf \
	swift-hash swift_hash_path_prefix "${SWIFT_HASH_PATH_SUFFIX}"
    crudini --set /etc/swift/swift.conf \
	storage-policy:0 name "Policy-0"
    crudini --set /etc/swift/swift.conf \
	storage-policy:0 default yes

    chown -R swift:swift /etc/swift

    service_restart memcached
    service_restart rsyslog
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	swift-init proxy-server restart
    else
	service_restart swift-proxy
    fi
    service_enable swift-proxy

    echo "SWIFT_PASS=\"${SWIFT_PASS}\"" >> $SETTINGS
    echo "SWIFT_HASH_PATH_PREFIX=\"${SWIFT_HASH_PATH_PREFIX}\"" >> $SETTINGS
    echo "SWIFT_HASH_PATH_SUFFIX=\"${SWIFT_HASH_PATH_SUFFIX}\"" >> $SETTINGS
    logtend "swift"
fi

if [ -z "${OBJECT_HOST_DONE}" ]; then
    logtstart "swift-host"
    fqdn=`getfqdn $OBJECTHOST`

    if [ "${OBJECTHOST}" = "${CONTROLLER}" ]; then
	$DIRNAME/setup-object-storage.sh
    else
        # Copy the latest settings (passwords, endpoints, whatever) over
	scp -o StrictHostKeyChecking=no $SETTINGS $fqdn:$SETTINGS

	ssh -o StrictHostKeyChecking=no $fqdn $DIRNAME/setup-object-storage.sh
    fi

    echo "OBJECT_HOST_DONE=\"1\"" >> $SETTINGS
    logtend "swift-host"
fi

if [ -z "${OBJECT_RING_DONE}" ]; then
    logtstart "swift-rings"
    cdir=`pwd`
    cd /etc/swift

    objip=`cat $OURDIR/mgmt-hosts | grep $OBJECTHOST | cut -d ' ' -f 1`

    swift-ring-builder account.builder create 10 2 1
    swift-ring-builder account.builder \
	add r1z1-${objip}:6002/swiftv1 100
    swift-ring-builder account.builder \
	add r1z1-${objip}:6002/swiftv1-2 100
    swift-ring-builder account.builder rebalance

    swift-ring-builder container.builder create 10 2 1
    swift-ring-builder container.builder \
	add r1z1-${objip}:6001/swiftv1 100
    swift-ring-builder container.builder \
	add r1z1-${objip}:6001/swiftv1-2 100
    swift-ring-builder container.builder rebalance

    swift-ring-builder object.builder create 10 2 1
    swift-ring-builder object.builder \
	add r1z1-${objip}:6000/swiftv1 100
    swift-ring-builder object.builder \
	add r1z1-${objip}:6000/swiftv1-2 100
    swift-ring-builder object.builder rebalance

    chown -R swift:swift /etc/swift

    if [ "${OBJECTHOST}" != "${CONTROLLER}" ]; then
        # Copy the latest settings
	scp -o StrictHostKeyChecking=no account.ring.gz container.ring.gz object.ring.gz $OBJECTHOST:/etc/swift
    fi

    cd $cdir

    echo "OBJECT_RING_DONE=\"1\"" >> $SETTINGS
    logtend "swift-rings"
fi

#
# Get Orchestrated
#
if [ -z "${HEAT_DBPASS}" ]; then
    logtstart "heat"
    HEAT_DBPASS=`$PSWDGEN`
    HEAT_PASS=`$PSWDGEN`
    HEAT_DOMAIN_PASS=`$PSWDGEN`

    echo "create database heat" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on heat.* to 'heat'@'localhost' identified by '$HEAT_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on heat.* to 'heat'@'%' identified by '$HEAT_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    if [ $OSVERSION -eq $OSJUNO ]; then
	keystone user-create --name heat --pass $HEAT_PASS
	keystone user-role-add --user heat --tenant service --role admin
	keystone role-create --name heat_stack_owner
	#keystone user-role-add --user demo --tenant demo --role heat_stack_owner
	keystone role-create --name heat_stack_user

	keystone service-create --name heat --type orchestration \
		 --description "OpenStack Orchestration Service"
	keystone service-create --name heat-cfn --type cloudformation \
		 --description "OpenStack Orchestration Service"

	keystone endpoint-create \
            --service-id $(keystone service-list | awk '/ orchestration / {print $2}') \
	    --publicurl http://${CONTROLLER}:8004/v1/%\(tenant_id\)s \
	    --internalurl http://${CONTROLLER}:8004/v1/%\(tenant_id\)s \
	    --adminurl http://${CONTROLLER}:8004/v1/%\(tenant_id\)s \
	    --region $REGION
	keystone endpoint-create \
	    --service-id $(keystone service-list | awk '/ cloudformation / {print $2}') \
	    --publicurl http://${CONTROLLER}:8000/v1 \
	    --internalurl http://${CONTROLLER}:8000/v1 \
	    --adminurl http://${CONTROLLER}:8000/v1 \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $HEAT_PASS heat
	__openstack role add --user heat --project service admin
	__openstack role create heat_stack_owner
	__openstack role create heat_stack_user
	__openstack service create --name heat \
	    --description "OpenStack Orchestration Service" orchestration
	__openstack service create --name heat-cfn \
	    --description "OpenStack Orchestration Service" cloudformation

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://$CONTROLLER:8004/v1/%\(tenant_id\)s \
		--internalurl http://$CONTROLLER:8004/v1/%\(tenant_id\)s \
		--adminurl http://$CONTROLLER:8004/v1/%\(tenant_id\)s \
		--region $REGION orchestration
	    __openstack endpoint create \
		--publicurl http://$CONTROLLER:8000/v1 \
		--internalurl http://$CONTROLLER:8000/v1 \
		--adminurl http://$CONTROLLER:8000/v1 \
		--region RegionOne \
		cloudformation
	else
	    __openstack endpoint create --region $REGION \
		orchestration public http://${CONTROLLER}:8004/v1/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		orchestration internal http://${CONTROLLER}:8004/v1/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		orchestration admin http://${CONTROLLER}:8004/v1/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		cloudformation public http://${CONTROLLER}:8000/v1
	    __openstack endpoint create --region $REGION \
		cloudformation internal http://${CONTROLLER}:8000/v1
	    __openstack endpoint create --region $REGION \
		cloudformation admin http://${CONTROLLER}:8000/v1

	    __openstack domain create --description "Stack projects and users" heat
	    __openstack user create --domain heat \
		--password $HEAT_DOMAIN_PASS heat_domain_admin
	    __openstack role add --domain heat --user heat_domain_admin admin
	    # Do this for admin, not demo, for now
	    __openstack role add --project admin --user admin heat_stack_owner
	    __openstack role add --project admin --user adminapi heat_stack_owner
	fi
    fi

    maybe_install_packages heat-api heat-api-cfn heat-engine python-heatclient

    crudini --set /etc/heat/heat.conf database \
	connection "${DBDSTRING}://heat:${HEAT_DBPASS}@$CONTROLLER/heat"
    crudini --set /etc/heat/heat.conf DEFAULT auth_strategy keystone
    crudini --set /etc/heat/heat.conf DEFAULT my_ip ${MGMTIP}
    crudini --set /etc/heat/heat.conf glance host $CONTROLLER
    crudini --set /etc/heat/heat.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/heat/heat.conf DEFAULT debug ${DEBUG_LOGGING}

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/heat/heat.conf DEFAULT rpc_backend rabbit
	crudini --set /etc/heat/heat.conf DEFAULT rabbit_host $CONTROLLER
	crudini --set /etc/heat/heat.conf DEFAULT rabbit_userid ${RABBIT_USER}
	crudini --set /etc/heat/heat.conf DEFAULT rabbit_password "${RABBIT_PASS}"
    elif [ $OSVERSION -lt $OSNEWTON ]; then
	crudini --set /etc/heat/heat.conf DEFAULT rpc_backend rabbit
	crudini --set /etc/heat/heat.conf oslo_messaging_rabbit \
	    rabbit_host $CONTROLLER
	crudini --set /etc/heat/heat.conf oslo_messaging_rabbit \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/heat/heat.conf oslo_messaging_rabbit \
	    rabbit_password "${RABBIT_PASS}"
    else
	crudini --set /etc/heat/heat.conf DEFAULT transport_url $RABBIT_URL
    fi

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    identity_uri http://${CONTROLLER}:35357
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    admin_tenant_name service
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    admin_user heat
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    admin_password "${HEAT_PASS}"
    else
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    ${AUTH_TYPE_PARAM} password
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    ${PROJECT_DOMAIN_PARAM} default
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    ${USER_DOMAIN_PARAM} default
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    project_name service
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    username heat
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    password "${HEAT_PASS}"
    fi
    if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	crudini --set /etc/heat/heat.conf keystone_authtoken \
	    memcached_servers ${CONTROLLER}:11211
    fi

    if [ $OSVERSION -gt $OSMITAKA ]; then
	crudini --set /etc/heat/heat.conf trustee \
	    ${AUTH_TYPE_PARAM} password
    else
	crudini --set /etc/heat/heat.conf trustee \
	    auth_plugin password
    fi
    if [ $OSVERSION -ge $OSLIBERTY ]; then
	crudini --set /etc/heat/heat.conf trustee \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/heat/heat.conf trustee \
	    username heat
	crudini --set /etc/heat/heat.conf trustee \
	    password ${HEAT_PASS}
	crudini --set /etc/heat/heat.conf trustee \
	    ${USER_DOMAIN_PARAM} default

	crudini --set /etc/heat/heat.conf clients_keystone \
	    auth_uri http://${CONTROLLER}:5000
    fi

    crudini --set /etc/heat/heat.conf DEFAULT \
	heat_metadata_server_url http://$CONTROLLER:8000
    crudini --set /etc/heat/heat.conf DEFAULT \
	heat_waitcondition_server_url http://$CONTROLLER:8000/v1/waitcondition

    if [ "x$KEYSTONEAPIVERSION" = "x3" ]; then
	crudini --set /etc/heat/heat.conf ec2authtoken \
		auth_uri http://${CONTROLLER}:5000
    else
	crudini --set /etc/heat/heat.conf ec2authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
    fi

    if [ $OSVERSION -ge $OSKILO ]; then
	crudini --set /etc/heat/heat.conf DEFAULT \
	    stack_domain_admin heat_domain_admin
	crudini --set /etc/heat/heat.conf DEFAULT \
	    stack_domain_admin_password $HEAT_DOMAIN_PASS
	crudini --set /etc/heat/heat.conf DEFAULT \
	    stack_user_domain_name heat
    fi

    crudini --del /etc/heat/heat.conf DEFAULT auth_host
    crudini --del /etc/heat/heat.conf DEFAULT auth_port
    crudini --del /etc/heat/heat.conf DEFAULT auth_protocol

    if [ $OSVERSION -eq $OSKILO ]; then
	heat-keystone-setup-domain \
	    --stack-user-domain-name heat_user_domain \
	    --stack-domain-admin heat_domain_admin \
	    --stack-domain-admin-password ${HEAT_DOMAIN_PASS}
    fi

    su -s /bin/sh -c "/usr/bin/heat-manage db_sync" heat

    service_restart heat-api
    service_enable heat-api
    service_restart heat-api-cfn
    service_enable heat-api-cfn
    service_restart heat-engine
    service_enable heat-engine

    rm -f /var/lib/heat/heat.sqlite

    echo "HEAT_DBPASS=\"${HEAT_DBPASS}\"" >> $SETTINGS
    echo "HEAT_PASS=\"${HEAT_PASS}\"" >> $SETTINGS
    echo "HEAT_DOMAIN_PASS=\"${HEAT_DOMAIN_PASS}\"" >> $SETTINGS
    logtend "heat"
fi

#
# Get Telemeterized
#
if [ -z "${CEILOMETER_DBPASS}" ]; then
    logtstart "ceilometer"
    CEILOMETER_DBPASS=`$PSWDGEN`
    CEILOMETER_PASS=`$PSWDGEN`
    CEILOMETER_SECRET=`$PSWDGEN`

    if [ "${CEILOMETER_USE_MONGODB}" = "1" ]; then
	maybe_install_packages mongodb-server python-pymongo
	maybe_install_packages mongodb-clients

	sed -i -e "s/^.*bind_ip.*=.*$/bind_ip = ${MGMTIP}/" /etc/mongodb.conf

	echo "smallfiles = true" >> /etc/mongodb.conf
	service_stop mongodb
	rm /var/lib/mongodb/journal/prealloc.*
	service_start mongodb
	service_enable mongodb

	MDONE=1
	while [ $MDONE -ne 0 ]; do 
	    sleep 1
	    mongo --host ${MGMTIP} --eval "db = db.getSiblingDB(\"ceilometer\"); db.addUser({user: \"ceilometer\", pwd: \"${CEILOMETER_DBPASS}\", roles: [ \"readWrite\", \"dbAdmin\" ]})"
	    MDONE=$?
	done
    else
	maybe_install_packages mariadb-server python-mysqldb

	echo "create database ceilometer" | mysql -u root --password="$DB_ROOT_PASS"
	echo "grant all privileges on ceilometer.* to 'ceilometer'@'localhost' identified by '$CEILOMETER_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
	echo "grant all privileges on ceilometer.* to 'ceilometer'@'%' identified by '$CEILOMETER_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    fi

    if [ $OSVERSION -eq $OSJUNO ]; then
	keystone user-create --name ceilometer --pass $CEILOMETER_PASS
	keystone user-role-add --user ceilometer --tenant service --role admin
	keystone service-create --name ceilometer --type metering \
	    --description "OpenStack Telemetry Service"

	keystone endpoint-create \
	    --service-id $(keystone service-list | awk '/ metering / {print $2}') \
	    --publicurl http://${CONTROLLER}:8777 \
	    --internalurl http://${CONTROLLER}:8777 \
	    --adminurl http://${CONTROLLER}:8777 \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $CEILOMETER_PASS ceilometer
	__openstack role add --user ceilometer --project service admin
	__openstack service create --name ceilometer \
	    --description "OpenStack Telemetry Service" metering

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://$CONTROLLER:8777 \
		--internalurl http://$CONTROLLER:8777 \
		--adminurl http://$CONTROLLER:8777 \
		--region $REGION metering
	# Don't do this for now despite Ocata install instructions; the
	# package's wsgi file's port is still 8777.
	#elif [ $OSVERSION -ge $OSOCATA ]; then
	#    __openstack endpoint create --region $REGION \
	#	metering public http://${CONTROLLER}:8041
	#    __openstack endpoint create --region $REGION \
	#	metering internal http://${CONTROLLER}:8041
	#    __openstack endpoint create --region $REGION \
	#	metering admin http://${CONTROLLER}:8041
	else
	    __openstack endpoint create --region $REGION \
		metering public http://${CONTROLLER}:8777
	    __openstack endpoint create --region $REGION \
		metering internal http://${CONTROLLER}:8777
	    __openstack endpoint create --region $REGION \
		metering admin http://${CONTROLLER}:8777
	fi
    fi

    maybe_install_packages ceilometer-api ceilometer-collector \
	ceilometer-agent-central ceilometer-agent-notification \
	python-ceilometerclient python-bson

    if [ $OSVERSION -lt $OSMITAKA ]; then
	maybe_install_packages ceilometer-alarm-evaluator \
	    ceilometer-alarm-notifier
    fi

    if [ "${CEILOMETER_USE_MONGODB}" = "1" ]; then
	crudini --set /etc/ceilometer/ceilometer.conf database \
	    connection "mongodb://ceilometer:${CEILOMETER_DBPASS}@${MGMTIP}:27017/ceilometer" 
    else
	crudini --set /etc/ceilometer/ceilometer.conf database \
	    connection "${DBDSTRING}://ceilometer:${CEILOMETER_DBPASS}@$CONTROLLER/ceilometer?charset=utf8"
    fi

    crudini --set /etc/ceilometer/ceilometer.conf DEFAULT auth_strategy keystone
    crudini --set /etc/ceilometer/ceilometer.conf glance host $CONTROLLER
    crudini --set /etc/ceilometer/ceilometer.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/ceilometer/ceilometer.conf DEFAULT debug ${DEBUG_LOGGING}
    crudini --set /etc/ceilometer/ceilometer.conf DEFAULT \
	log_dir /var/log/ceilometer

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/ceilometer/ceilometer.conf DEFAULT rpc_backend rabbit
	crudini --set /etc/ceilometer/ceilometer.conf DEFAULT rabbit_host $CONTROLLER
	crudini --set /etc/ceilometer/ceilometer.conf DEFAULT rabbit_userid ${RABBIT_USER}
	crudini --set /etc/ceilometer/ceilometer.conf DEFAULT rabbit_password "${RABBIT_PASS}"
    elif [ $OSVERSION -lt $OSNEWTON ]; then
	crudini --set /etc/ceilometer/ceilometer.conf DEFAULT rpc_backend rabbit
	crudini --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit \
	    rabbit_host $CONTROLLER
	crudini --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit \
	    rabbit_password "${RABBIT_PASS}"
    else
	crudini --set /etc/ceilometer/ceilometer.conf DEFAULT transport_url $RABBIT_URL
    fi

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    identity_uri http://${CONTROLLER}:35357
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    admin_tenant_name service
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    admin_user ceilometer
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    admin_password "${CEILOMETER_PASS}"
    else
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    ${AUTH_TYPE_PARAM} password
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    ${PROJECT_DOMAIN_PARAM} default
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    ${USER_DOMAIN_PARAM} default
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    project_name service
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    username ceilometer
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    password "${CEILOMETER_PASS}"
    fi
    if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	crudini --set /etc/ceilometer/ceilometer.conf keystone_authtoken \
	    memcached_servers  ${CONTROLLER}:11211
    fi

    if [ $OSVERSION -lt $OSMITAKA ]; then
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    os_auth_url http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    os_username ceilometer
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    os_tenant_name service
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    os_password ${CEILOMETER_PASS}
	if [ $OSVERSION -ge $OSKILO ]; then
	    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
		os_endpoint_type internalURL
	    crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
		os_region_name $REGION
	fi
    else
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    auth_type password
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    auth_url http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    username ceilometer
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    ${PROJECT_DOMAIN_PARAM} default
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    ${USER_DOMAIN_PARAM} default
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    project_name service
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    password ${CEILOMETER_PASS}
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    interface internalURL
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    region_name $REGION
    fi
    if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	crudini --set /etc/ceilometer/ceilometer.conf service_credentials \
	    memcached_servers ${CONTROLLER}:11211
    fi

    crudini --set /etc/ceilometer/ceilometer.conf notification \
	store_events true
    crudini --set /etc/ceilometer/ceilometer.conf notification \
	disable_non_metric_meters false

    if [ $OSVERSION -le $OSJUNO ]; then
	crudini --set /etc/ceilometer/ceilometer.conf publisher \
	    metering_secret ${CEILOMETER_SECRET}
    else
	crudini --set /etc/ceilometer/ceilometer.conf publisher \
	    telemetry_secret ${CEILOMETER_SECRET}
    fi

    crudini --del /etc/ceilometer/ceilometer.conf DEFAULT auth_host
    crudini --del /etc/ceilometer/ceilometer.conf DEFAULT auth_port
    crudini --del /etc/ceilometer/ceilometer.conf DEFAULT auth_protocol

    if [ ! -e /etc/ceilometer/event_pipeline.yaml ]; then
	cat <<EOF > /etc/ceilometer/event_pipeline.yaml
sources:
    - name: event_source
      events:
          - "*"
      sinks:
          - event_sink
sinks:
    - name: event_sink
      transformers:
      triggers:
      publishers:
          - notifier://
EOF
    fi

    su -s /bin/sh -c "ceilometer-dbsync" ceilometer

    service_restart ceilometer-agent-central
    service_enable ceilometer-agent-central
    service_restart ceilometer-agent-notification
    service_enable ceilometer-agent-notification

    if [ $CEILOMETER_USE_WSGI -eq 1 -a $OSVERSION -lt $OSOCATA ]; then
	cat <<EOF > /etc/apache2/sites-available/ceilometer-api.conf
Listen 8777

<VirtualHost *:8777>
    WSGIDaemonProcess ceilometer-api processes=2 threads=10 user=ceilometer display-name=%{GROUP}
    WSGIProcessGroup ceilometer-api
    WSGIScriptAlias / /usr/bin/ceilometer-wsgi-app
    WSGIApplicationGroup %{GLOBAL}
#    WSGIPassAuthorization On
    <IfVersion >= 2.4>
       ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    ErrorLog /var/log/apache2/ceilometer_error.log
    CustomLog /var/log/apache2/ceilometer_access.log combined
    <Directory /usr/bin>
        <IfVersion >= 2.4>
            Require all granted
        </IfVersion>
        <IfVersion < 2.4>
            Order allow,deny
            Allow from all
        </IfVersion>
    </Directory>
</VirtualHost>
EOF

	a2ensite ceilometer-api
	wget -O /usr/bin/ceilometer-wsgi-app https://raw.githubusercontent.com/openstack/ceilometer/stable/${OSCODENAME}/ceilometer/api/app.wsgi
	if [ ! $? -eq 0 ]; then
            # Try the EOL version
            wget -O /usr/bin/ceilometer-wsgi-app https://raw.githubusercontent.com/openstack/ceilometer/${OSCODENAME}-eol/ceilometer/api/app.wsgi
	fi
	
	service apache2 reload
    elif [ $OSVERSION -ge $OSOCATA ]; then
	a2ensite ceilometer-api.conf
	service_restart apache2
    else
	service_restart ceilometer-api
	service_enable ceilometer-api
    fi

    #
    # Patch for https://bugs.launchpad.net/python-ceilometerclient/+bug/1679934 ;
    # hasn't hit Ubuntu Ocata cloud archive packages yet.
    #
    if [ $OSVERSION -eq $OSOCATA ]; then
	patch -p1 -d / < $DIRNAME/etc/ceilometer-ocata-client-bug-1679934.patch
    fi

    service_restart ceilometer-collector
    service_enable ceilometer-collector
    if [ $OSVERSION -lt $OSMITAKA ]; then
	service_restart ceilometer-alarm-evaluator
	service_enable ceilometer-alarm-evaluator
	service_restart ceilometer-alarm-notifier
	service_enable ceilometer-alarm-notifier
    fi

    # NB: restart the neutron ceilometer agent too
    if ! unified ; then
	fqdn=`getfqdn $NETWORKMANAGER`
	ssh -o StrictHostKeyChecking=no $fqdn service neutron-metering-agent restart
    else
	service neutron-metering-agent restart
    fi

    echo "CEILOMETER_DBPASS=\"${CEILOMETER_DBPASS}\"" >> $SETTINGS
    echo "CEILOMETER_PASS=\"${CEILOMETER_PASS}\"" >> $SETTINGS
    echo "CEILOMETER_SECRET=\"${CEILOMETER_SECRET}\"" >> $SETTINGS
    logtend "ceilometer"
fi

#
# Install the Telemetry service on the compute nodes
#
if [ -z "${TELEMETRY_COMPUTENODES_DONE}" ]; then
    logtstart "ceilometer-nodes"
    TELEMETRY_COMPUTENODES_DONE=1

    PHOSTS=""
    mkdir -p $OURDIR/pssh.setup-compute-telemetry.stdout \
	$OURDIR/pssh.setup-compute-telemetry.stderr

    for node in $COMPUTENODES
    do
	fqdn=`getfqdn $node`

	# Copy the latest settings (passwords, endpoints, whatever) over
	scp -o StrictHostKeyChecking=no $SETTINGS $fqdn:$SETTINGS

	PHOSTS="$PHOSTS -H $fqdn"
    done

    echo "*** Setting up Compute telemetry on nodes: $PHOSTS"
    $PSSH $PHOSTS -o $OURDIR/pssh.setup-compute-telemetry.stdout \
	-e $OURDIR/pssh.setup-compute-telemetry.stderr \
	$DIRNAME/setup-compute-telemetry.sh

    for node in $COMPUTENODES
    do
	touch $OURDIR/compute-telemetry-done-${node}
    done

    echo "TELEMETRY_COMPUTENODES_DONE=\"${TELEMETRY_COMPUTENODES_DONE}\"" >> $SETTINGS
    logtend "ceilometer-nodes"
fi

#
# Install the Telemetry service for Glance
#
if [ -z "${TELEMETRY_GLANCE_DONE}" ]; then
    logtstart "ceilometer-glance"
    TELEMETRY_GLANCE_DONE=1

    if [ $OSVERSION -ge $OSLIBERTY ]; then
	RIS=oslo_messaging_rabbit
    else
	RIS=DEFAULT
    fi

    if [ $OSVERSION -lt $OSMITAKA ]; then
	crudini --set /etc/glance/glance-api.conf DEFAULT \
	    notification_driver messagingv2
    else
	crudini --set /etc/glance/glance-api.conf \
	    oslo_messaging_notifications driver messagingv2
    fi
    if [ $OSVERSION -lt $OSNEWTON ]; then
	crudini --set /etc/glance/glance-api.conf DEFAULT \
	    rpc_backend rabbit
	crudini --set /etc/glance/glance-api.conf $RIS \
 	    rabbit_host ${CONTROLLER}
	crudini --set /etc/glance/glance-api.conf $RIS \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/glance/glance-api.conf $RIS \
	    rabbit_password ${RABBIT_PASS}
    else
	crudini --set /etc/glance/glance-api.conf DEFAULT transport_url $RABBIT_URL
    fi
    if [ $OSVERSION -lt $OSMITAKA ]; then
	crudini --set /etc/glance/glance-registry.conf DEFAULT \
	    notification_driver messagingv2
    else
	crudini --set /etc/glance/glance-registry.conf \
	    oslo_messaging_notifications driver messagingv2
    fi
    if [ $OSVERSION -lt $OSNEWTON ]; then
	crudini --set /etc/glance/glance-registry.conf DEFAULT \
	    rpc_backend rabbit
	crudini --set /etc/glance/glance-registry.conf $RIS \
	    rabbit_host ${CONTROLLER}
	crudini --set /etc/glance/glance-registry.conf $RIS \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/glance/glance-registry.conf $RIS \
	    rabbit_password ${RABBIT_PASS}
    else
	crudini --set /etc/glance/glance-api.conf DEFAULT transport_url $RABBIT_URL
    fi

    service_restart glance-registry
    service_restart glance-api

    echo "TELEMETRY_GLANCE_DONE=\"${TELEMETRY_GLANCE_DONE}\"" >> $SETTINGS
    logtend "ceilometer-glance"
fi

#
# Install the Telemetry service for Cinder
#
if [ -z "${TELEMETRY_CINDER_DONE}" ]; then
    logtstart "ceilometer-cinder"
    TELEMETRY_CINDER_DONE=1

    crudini --set /etc/cinder/cinder.conf DEFAULT control_exchange cinder
    crudini --set /etc/cinder/cinder.conf DEFAULT notification_driver messagingv2

    service_restart cinder-api
    service_restart cinder-scheduler

    fqdn=`getfqdn $STORAGEHOST`

    if [ "${STORAGEHOST}" = "${CONTROLLER}" ]; then
	$DIRNAME/setup-storage-telemetry.sh
    else
        # Copy the latest settings (passwords, endpoints, whatever) over
	scp -o StrictHostKeyChecking=no $SETTINGS $fqdn:$SETTINGS

	ssh -o StrictHostKeyChecking=no $fqdn $DIRNAME/setup-storage-telemetry.sh
    fi

    echo "TELEMETRY_CINDER_DONE=\"${TELEMETRY_CINDER_DONE}\"" >> $SETTINGS
    logtend "ceilometer-cinder"
fi

#
# Install the Telemetry service for Swift
#
if [ -z "${TELEMETRY_SWIFT_DONE}" ]; then
    logtstart "ceilometer-swift"
    TELEMETRY_SWIFT_DONE=1

    chmod g+w /var/log/ceilometer

    maybe_install_packages python-ceilometerclient python-ceilometermiddleware

    if [ $OSVERSION -le $OSJUNO ]; then
	keystone role-create --name ResellerAdmin
	keystone user-role-add --tenant service --user ceilometer \
		 --role $(keystone role-list | awk '/ ResellerAdmin / {print $2}')
    else
	__openstack role create ResellerAdmin
	__openstack role add --project service --user ceilometer ResellerAdmin
    fi

    if [ $OSVERSION -le $OSKILO ]; then
	crudini --set /etc/swift/proxy-server.conf filter:ceilometer \
		use 'egg:ceilometer#swift'
    fi

    if [ $OSVERSION -ge $OSKILO ]; then
	crudini --set /etc/swift/proxy-server.conf filter:keystoneauth \
	    operator_roles 'admin, user, ResellerAdmin'

	crudini --set /etc/swift/proxy-server.conf filter:ceilometer \
	    paste.filter_factory ceilometermiddleware.swift:filter_factory
	crudini --set /etc/swift/proxy-server.conf filter:ceilometer \
	    control_exchange swift
	crudini --set /etc/swift/proxy-server.conf filter:ceilometer \
	    url rabbit://${RABBIT_USER}:${RABBIT_PASS}@${CONTROLLER}:5672/
	crudini --set /etc/swift/proxy-server.conf filter:ceilometer \
	    driver messagingv2
	crudini --set /etc/swift/proxy-server.conf filter:ceilometer \
	    topic notifications
	crudini --set /etc/swift/proxy-server.conf filter:ceilometer \
	    log_level WARN
    fi

    usermod -a -G ceilometer swift

    sed -i -e 's/^\(pipeline.*=\)\(.*\)$/\1 ceilometer \2/' /etc/swift/proxy-server.conf
    sed -i -e 's/^\(operator_roles.*=.*\)$/\1,ResellerAdmin/' /etc/swift/proxy-server.conf

    service_restart swift-proxy
    #swift-init proxy-server restart

    echo "TELEMETRY_SWIFT_DONE=\"${TELEMETRY_SWIFT_DONE}\"" >> $SETTINGS
    logtend "ceilometer-swift"
fi

#
# Install the Telemetry service for Heat
#
if [ -z "${TELEMETRY_HEAT_DONE}" ]; then
    logtstart "ceilometer-heat"
    TELEMETRY_HEAT_DONE=1

    if [ $OSVERSION -lt $OSMITAKA ]; then
	crudini --set /etc/heat/heat.conf DEFAULT \
	    notification_driver messagingv2
    else
	crudini --set /etc/heat/heat.conf \
	    oslo_messaging_notifications driver messagingv2
    fi
    service_restart heat-api
    service_restart heat-api-cfn
    service_restart heat-engine

    echo "TELEMETRY_HEAT_DONE=\"${TELEMETRY_HEAT_DONE}\"" >> $SETTINGS
    logtend "ceilometer-heat"
fi

#
# Get Us Some Databases!
#
if [ -z "${TROVE_DBPASS}" ]; then
    logtstart "trove"
    TROVE_DBPASS=`$PSWDGEN`
    TROVE_PASS=`$PSWDGEN`

    # trove on Ubuntu Vivid was broken at the time this was done...
    maybe_install_packages trove-common
    if [ ! $? -eq 0 ]; then
	touch /var/lib/trove/trove_test.sqlite
	chown trove:trove /var/lib/trove/trove_test.sqlite
	crudini --set /etc/trove/trove.conf database connection sqlite:////var/lib/trove/trove_test.sqlite
	maybe_install_packages trove-common
    fi

    maybe_install_packages python-trove python-troveclient python-glanceclient \
	trove-api trove-taskmanager trove-conductor
    if [ $OSVERSION -ge $OSMITAKA ]; then
	sepdashpkg=`apt-cache search --names-only ^python-trove-dashboard\$ | wc -l`
	if [ ! "$sepdashpkg" = "0" ]; then
            # Bug in mitaka package -- postinstall fails to remove this file.
	    madedir=0
	    if [ ! -f /var/lib/openstack-dashboard/secret-key/.secret_key_store ]; then
		if [ ! -d /var/lib/openstack-dashboard/secret-key ]; then
		    madedir=1
		    mkdir -p /var/lib/openstack-dashboard/secret-key
		fi
		touch /var/lib/openstack-dashboard/secret-key/.secret_key_store
	    fi

	    maybe_install_packages python-trove-dashboard

	    if [ $madedir -eq 1 ]; then
		rm -rf /var/lib/openstack-dashboard/secret-key
	    fi
	fi
    fi

    echo "create database trove" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on trove.* to 'trove'@'localhost' identified by '$TROVE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on trove.* to 'trove'@'%' identified by '$TROVE_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    if [ $OSVERSION -eq $OSJUNO ]; then
	keystone user-create --name trove --pass $TROVE_PASS
	keystone user-role-add --user trove --tenant service --role admin

	keystone service-create --name trove --type database \
	    --description "OpenStack Database Service"

	keystone endpoint-create \
	    --service-id $(keystone service-list | awk '/ trove / {print $2}') \
	    --publicurl http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s \
	    --internalurl http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s \
	    --adminurl http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $TROVE_PASS trove
	__openstack role add --user trove --project service admin
	__openstack service create --name trove \
	    --description "OpenStack Database Service" database

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s \
		--internalurl http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s \
		--adminurl http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s \
		--region $REGION \
		database
	else
	    __openstack endpoint create --region $REGION \
		database public http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		database internal http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		database admin http://${CONTROLLER}:8779/v1.0/%\(tenant_id\)s
	fi
    fi

    # trove.conf core stuff
    crudini --set /etc/trove/trove.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/trove/trove.conf DEFAULT debug ${DEBUG_LOGGING}
    crudini --set /etc/trove/trove.conf DEFAULT log_dir /var/log/trove
    crudini --set /etc/ceilometer/ceilometer.conf DEFAULT bind_host ${MGMTIP}
    if [ $OSVERSION -lt $OSLIBERTY ]; then
	crudini --set /etc/trove/trove.conf DEFAULT rpc_backend rabbit
	crudini --set /etc/trove/trove.conf DEFAULT rabbit_host ${CONTROLLER}
	crudini --set /etc/trove/trove.conf DEFAULT rabbit_userid ${RABBIT_USER}
	crudini --set /etc/trove/trove.conf DEFAULT rabbit_password ${RABBIT_PASS}
    elif [ $OSVERSION -lt $OSNEWTON ]; then
	crudini --set /etc/trove/trove.conf DEFAULT rpc_backend rabbit
	crudini --set /etc/trove/trove.conf oslo_messaging_rabbit \
	    rabbit_host ${CONTROLLER}
	crudini --set /etc/trove/trove.conf oslo_messaging_rabbit \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/trove/trove.conf oslo_messaging_rabbit \
	    rabbit_password ${RABBIT_PASS}
    else
	crudini --set /etc/trove/trove.conf DEFAULT transport_url $RABBIT_URL
    fi
    crudini --set /etc/trove/trove.conf DEFAULT \
	trove_auth_url http://${CONTROLLER}:5000/${KAPISTR}
    crudini --set /etc/trove/trove.conf DEFAULT \
	nova_compute_url http://${CONTROLLER}:8774/${NAPISTR}
    crudini --set /etc/trove/trove.conf DEFAULT \
	cinder_url http://${CONTROLLER}:8776/v1
    crudini --set /etc/trove/trove.conf DEFAULT \
	swift_url http://${CONTROLLER}:8080/v1/AUTH_
    # XXX: not sure when this got replaced by database::connection...
    crudini --set /etc/trove/trove.conf DEFAULT \
	sql_connection ${DBDSTRING}://trove:${TROVE_DBPASS}@${CONTROLLER}/trove
    crudini --set /etc/trove/trove.conf \
	database connection ${DBDSTRING}://trove:${TROVE_DBPASS}@${CONTROLLER}/trove
    crudini --set /etc/trove/trove.conf DEFAULT \
	notifier_queue_hostname ${CONTROLLER}

    # trove-taskmanager.conf core stuff
    crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	verbose ${VERBOSE_LOGGING}
    crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	debug ${DEBUG_LOGGING}
    crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	log_dir /var/log/trove
    if [ $OSVERSION -lt $OSLIBERTY ]; then
	crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	    rpc_backend rabbit
	crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	    rabbit_host ${CONTROLLER}
	crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	    rabbit_password ${RABBIT_PASS}
    elif [ $OSVERSION -lt $OSNEWTON ]; then
	crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	    rpc_backend rabbit
	crudini --set /etc/trove/trove-taskmanager.conf oslo_messaging_rabbit \
	    rabbit_host ${CONTROLLER}
	crudini --set /etc/trove/trove-taskmanager.conf oslo_messaging_rabbit \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/trove/trove-taskmanager.conf oslo_messaging_rabbit \
	    rabbit_password ${RABBIT_PASS}
    else
	crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	    transport_url $RABBIT_URL
    fi
    crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	trove_auth_url http://${CONTROLLER}:5000/${KAPISTR}
    crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	nova_compute_url http://${CONTROLLER}:8774/${NAPISTR}
    crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	cinder_url http://${CONTROLLER}:8776/v1
    crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	swift_url http://${CONTROLLER}:8080/v1/AUTH_
    # XXX: not sure when this got replaced by database::connection...
    crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	sql_connection ${DBDSTRING}://trove:${TROVE_DBPASS}@${CONTROLLER}/trove
    crudini --set /etc/trove/trove-taskmanager.conf \
	database connection ${DBDSTRING}://trove:${TROVE_DBPASS}@${CONTROLLER}/trove
    crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	notifier_queue_hostname ${CONTROLLER}

    # trove-conductor.conf core stuff
    crudini --set /etc/trove/trove-conductor.conf DEFAULT \
	verbose ${VERBOSE_LOGGING}
    crudini --set /etc/trove/trove-conductor.conf DEFAULT \
	debug ${DEBUG_LOGGING}
    crudini --set /etc/trove/trove-conductor.conf DEFAULT \
	log_dir /var/log/trove
    if [ $OSVERSION -lt $OSLIBERTY ]; then
	crudini --set /etc/trove/trove-conductor.conf DEFAULT \
	    rpc_backend rabbit
	crudini --set /etc/trove/trove-conductor.conf DEFAULT \
	    rabbit_host ${CONTROLLER}
	crudini --set /etc/trove/trove-conductor.conf DEFAULT \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/trove/trove-conductor.conf DEFAULT \
	    rabbit_password ${RABBIT_PASS}
    elif [ $OSVERSION -lt $OSNEWTON ]; then
	crudini --set /etc/trove/trove-conductor.conf DEFAULT \
	    rpc_backend rabbit
	crudini --set /etc/trove/trove-conductor.conf oslo_messaging_rabbit \
	    rabbit_host ${CONTROLLER}
	crudini --set /etc/trove/trove-conductor.conf oslo_messaging_rabbit \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/trove/trove-conductor.conf oslo_messaging_rabbit \
	    rabbit_password ${RABBIT_PASS}
    else
	crudini --set /etc/trove/trove-conductor.conf DEFAULT \
	    transport_url $RABBIT_URL
    fi
    crudini --set /etc/trove/trove-conductor.conf DEFAULT \
	trove_auth_url http://${CONTROLLER}:5000/${KAPISTR}
    crudini --set /etc/trove/trove-conductor.conf DEFAULT \
	nova_compute_url http://${CONTROLLER}:8774/${NAPISTR}
    crudini --set /etc/trove/trove-conductor.conf DEFAULT \
	cinder_url http://${CONTROLLER}:8776/v1
    crudini --set /etc/trove/trove-conductor.conf DEFAULT \
	swift_url http://${CONTROLLER}:8080/v1/AUTH_
    # XXX: not sure when this got replaced by database::connection...
    crudini --set /etc/trove/trove-conductor.conf DEFAULT \
	sql_connection ${DBDSTRING}://trove:${TROVE_DBPASS}@${CONTROLLER}/trove
    crudini --set /etc/trove/trove-conductor.conf \
	database connection ${DBDSTRING}://trove:${TROVE_DBPASS}@${CONTROLLER}/trove
    crudini --set /etc/trove/trove-conductor.conf DEFAULT \
	notifier_queue_hostname ${CONTROLLER}

    # A few extras for taskmanager.conf
    crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	nova_proxy_admin_user ${ADMIN_API}
    crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	nova_proxy_admin_pass ${ADMIN_API_PASS}
    crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	nova_proxy_admin_tenant_name service
    crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	taskmanager_manager trove.taskmanager.manager.Manager
    crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	
    crudini --set /etc/trove/trove-taskmanager.conf DEFAULT \
	
    # A few more things for the main conf file
    crudini --set /etc/trove/trove.conf DEFAULT default_datastore mysql
    crudini --set /etc/trove/trove.conf DEFAULT add_addresses True
    crudini --set /etc/trove/trove.conf DEFAULT \
	network_label_regex '^NETWORK_LABEL$'
    crudini --set /etc/trove/trove.conf DEFAULT \
	api_paste_config /etc/trove/api-paste.ini

    # Just slap these in.
    cat <<EOF >> /etc/trove/trove-guestagent.conf
[DEFAULT]
rabbit_host = ${CONTROLLER}
rabbit_userid = ${RABBIT_USER}
rabbit_password = ${RABBIT_PASS}
trove_auth_url = http://${CONTROLLER}:5000/${KAPISTR}
nova_proxy_admin_user = ${ADMIN_API}
nova_proxy_admin_pass = ${ADMIN_API_PASS}
nova_proxy_admin_tenant_name = service
taskmanager_manager = trove.taskmanager.manager.Manager
EOF

    if [ $OSVERSION -lt $OSKILO ]; then
	cat <<EOF >> /etc/trove/api-paste.ini
[filter:authtoken]
auth_uri = http://${CONTROLLER}:5000/${KAPISTR}
identity_uri = http://${CONTROLLER}:35357
admin_user = trove
admin_password = ${TROVE_PASS}
admin_tenant_name = service
signing_dir = /var/cache/trove
EOF
    else
	crudini --set /etc/trove/trove.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000
	crudini --set /etc/trove/trove.conf keystone_authtoken \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/trove/trove.conf keystone_authtoken \
	    ${AUTH_TYPE_PARAM} password
	crudini --set /etc/trove/trove.conf keystone_authtoken \
	    ${PROJECT_DOMAIN_PARAM} default
	crudini --set /etc/trove/trove.conf keystone_authtoken \
	    ${USER_DOMAIN_PARAM} default
	crudini --set /etc/trove/trove.conf keystone_authtoken \
	    project_name service
	crudini --set /etc/trove/trove.conf keystone_authtoken \
	    username trove
	crudini --set /etc/trove/trove.conf keystone_authtoken \
	    password ${TROVE_PASS}
	crudini --set /etc/trove/trove.conf keystone_authtoken \
	    region_name $REGION
    fi
    if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	crudini --set /etc/trove/trove.conf keystone_authtoken \
	    memcached_servers ${CONTROLLER}:11211
    fi

    sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/trove/api-paste.ini
    sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/trove/api-paste.ini
    sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/trove/api-paste.ini

    mkdir -p /var/cache/trove
    chown -R trove:trove /var/cache/trove

    sed -i.orig -E -e 's|(CONFIG_FILE=.*)$|CONFIG_FILE="/etc/trove/trove-taskmanager.conf"|' /etc/init/trove-taskmanager.conf
    sed -i.orig -E -e 's|(CONFIG_FILE=.*)$|CONFIG_FILE="/etc/trove/trove-conductor.conf"|' /etc/init/trove-conductor.conf
    sed -i.orig -E -e 's|(CONFIG_FILE=.*)$|CONFIG_FILE="/etc/trove/trove-taskmanager.conf"|' /etc/init.d/trove-taskmanager
    sed -i.orig -E -e 's|(CONFIG_FILE=.*)$|CONFIG_FILE="/etc/trove/trove-conductor.conf"|' /etc/init.d/trove-conductor
    if [ ${HAVE_SYSTEMD} -eq 1 ]; then
	systemctl daemon-reload
    fi

    su -s /bin/sh -c "/usr/bin/trove-manage db_sync" trove
    if [ ! $? -eq 0 ]; then
	#
        # Try disabling foreign_key_checks, sigh
        #
	echo "set global foreign_key_checks=0;" | mysql -u root --password="$DB_ROOT_PASS" trove
	su -s /bin/sh -c "/usr/bin/trove-manage db_sync" trove
	echo "set global foreign_key_checks=1;" | mysql -u root --password="$DB_ROOT_PASS" trove
    fi

    su -s /bin/sh -c "trove-manage datastore_update mysql ''" trove

    # XXX: Create a trove image!
    #maybe_install_packages qemu-utils kpartx
    #git clone https://git.openstack.org/openstack/diskimage-builder
    # trove-manage --config-file /etc/trove/trove.conf datastore_version_update \
    #    mysql mysql-5.5 mysql $glance_image_ID mysql-server-5.5 1

    service_restart trove-api
    service_enable trove-api
    service_restart trove-taskmanager
    service_enable trove-taskmanager
    service_restart trove-conductor
    service_enable trove-conductor

    service_restart apache2
    service_restart memcached

    echo "TROVE_DBPASS=\"${TROVE_DBPASS}\"" >> $SETTINGS
    echo "TROVE_PASS=\"${TROVE_PASS}\"" >> $SETTINGS
    logtend "trove"
fi

#
# Get some Data Processors!
#
if [ -z "${SAHARA_DBPASS}" ]; then
    logtstart "sahara"
    SAHARA_DBPASS=`$PSWDGEN`
    SAHARA_PASS=`$PSWDGEN`

    echo "create database sahara" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on sahara.* to 'sahara'@'localhost' identified by '$SAHARA_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on sahara.* to 'sahara'@'%' identified by '$SAHARA_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    if [ $OSVERSION -eq $OSJUNO ]; then
	keystone user-create --name sahara --pass $SAHARA_PASS
	keystone user-role-add --user sahara --tenant service --role admin

	keystone service-create --name sahara --type data_processing \
	    --description "OpenStack Data Processing Service"
	keystone endpoint-create \
	    --service-id $(keystone service-list | awk '/ sahara / {print $2}') \
	    --publicurl http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s \
	    --internalurl http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s \
	    --adminurl http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s \
	    --region $REGION
    else
	__openstack user create $DOMARG --password $SAHARA_PASS sahara
	__openstack role add --user sahara --project service admin
	__openstack service create --name sahara \
	    --description "OpenStack Data Processing Service" data_processing

	if [ $KEYSTONEAPIVERSION -lt 3 ]; then
	    __openstack endpoint create \
		--publicurl http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s \
		--internalurl http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s \
		--adminurl http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s \
		--region $REGION \
		data_processing
	else
	    __openstack endpoint create --region $REGION \
		data_processing public http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		data_processing internal http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s
	    __openstack endpoint create --region $REGION \
		data_processing admin http://${CONTROLLER}:8386/v1.1/%\(tenant_id\)s
	fi
    fi

    aserr=0
    apt-cache search ^sahara\$ | grep -q sahara
    if [ $? -eq 0 ] ; then
	APT_HAS_SAHARA=1
    else
	APT_HAS_SAHARA=0
    fi

    if [ ${APT_HAS_SAHARA} -eq 0 ]; then
        # XXX: http://askubuntu.com/questions/555093/openstack-juno-sahara-data-processing-on-14-04
	maybe_install_packages python-pip
        # sahara deps
	maybe_install_packages python-eventlet python-flask python-oslo.serialization
	pip install sahara
    else
	# This may fail because sahara's migration scripts use ALTER TABLE,
        # which sqlite doesn't support
	maybe_install_packages sahara-common 
	aserr=$?
	maybe_install_packages sahara-api sahara-engine
    fi
    if [ $OSVERSION -ge $OSMITAKA ]; then
	sepdashpkg=`apt-cache search --names-only ^python-sahara-dashboard\$ | wc -l`
	if [ ! "$sepdashpkg" = "0" ]; then
            # Bug in mitaka package -- postinstall fails to remove this file.
	    madedir=0
	    if [ ! -f /var/lib/openstack-dashboard/secret-key/.secret_key_store ]; then
		if [ ! -d /var/lib/openstack-dashboard/secret-key ]; then
		    madedir=1
		    mkdir -p /var/lib/openstack-dashboard/secret-key
		fi
		touch /var/lib/openstack-dashboard/secret-key/.secret_key_store
	    fi

	    maybe_install_packages python-sahara-dashboard

	    if [ $madedir -eq 1 ]; then
		rm -rf /var/lib/openstack-dashboard/secret-key
	    fi
	fi
    fi

    mkdir -p /etc/sahara
    touch /etc/sahara/sahara.conf
    chown -R sahara /etc/sahara
    crudini --set /etc/sahara/sahara.conf \
	database connection ${DBDSTRING}://sahara:${SAHARA_DBPASS}@$CONTROLLER/sahara
    crudini --set /etc/sahara/sahara.conf DEFAULT \
	verbose ${VERBOSE_LOGGING}
    crudini --set /etc/sahara/sahara.conf DEFAULT \
	debug ${DEBUG_LOGGING}
    crudini --set /etc/sahara/sahara.conf DEFAULT \
	auth_strategy keystone
    crudini --set /etc/sahara/sahara.conf DEFAULT \
	use_neutron true

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/sahara/sahara.conf DEFAULT rabbit_host $CONTROLLER
	crudini --set /etc/sahara/sahara.conf DEFAULT rabbit_userid ${RABBIT_USER}
	crudini --set /etc/sahara/sahara.conf DEFAULT rabbit_password "${RABBIT_PASS}"
    elif [ $OSVERSION -lt $OSNEWTON ]; then
	crudini --set /etc/sahara/sahara.conf oslo_messaging_rabbit \
	    rabbit_host $CONTROLLER
	crudini --set /etc/sahara/sahara.conf oslo_messaging_rabbit \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/sahara/sahara.conf oslo_messaging_rabbit \
	    rabbit_password "${RABBIT_PASS}"
    else
	crudini --set /etc/sahara/sahara.conf DEFAULT \
	    transport_url $RABBIT_URL
    fi

    if [ $OSVERSION -lt $OSKILO ]; then
	crudini --set /etc/sahara/sahara.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000/${KAPISTR}
	crudini --set /etc/sahara/sahara.conf keystone_authtoken \
	    identity_uri http://${CONTROLLER}:35357
	crudini --set /etc/sahara/sahara.conf keystone_authtoken \
	    admin_tenant_name service
	crudini --set /etc/sahara/sahara.conf keystone_authtoken \
	    admin_user sahara
	crudini --set /etc/sahara/sahara.conf keystone_authtoken \
	    admin_password "${SAHARA_PASS}"
    else
	crudini --set /etc/sahara/sahara.conf keystone_authtoken \
	    auth_uri http://${CONTROLLER}:5000
	crudini --set /etc/sahara/sahara.conf keystone_authtoken \
	    auth_url http://${CONTROLLER}:35357
	crudini --set /etc/sahara/sahara.conf keystone_authtoken \
	    ${AUTH_TYPE_PARAM} password
	crudini --set /etc/sahara/sahara.conf keystone_authtoken \
	    ${PROJECT_DOMAIN_PARAM} default
	crudini --set /etc/sahara/sahara.conf keystone_authtoken \
	    ${USER_DOMAIN_PARAM} default
	crudini --set /etc/sahara/sahara.conf keystone_authtoken \
	    project_name service
	crudini --set /etc/sahara/sahara.conf keystone_authtoken \
	    username sahara
	crudini --set /etc/sahara/sahara.conf keystone_authtoken \
	    password "${SAHARA_PASS}"
    fi
    if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
	crudini --set /etc/sahara/sahara.conf keystone_authtoken \
	    memcached_servers  ${CONTROLLER}:11211
    fi

    # Just slap these in.
    crudini --set /etc/sahara/sahara.conf ec2authtoken \
	auth_uri http://${CONTROLLER}:5000/${KAPISTR}

    sed -i -e "s/^\\(.*auth_host.*=.*\\)$/#\1/" /etc/sahara/sahara.conf
    sed -i -e "s/^\\(.*auth_port.*=.*\\)$/#\1/" /etc/sahara/sahara.conf
    sed -i -e "s/^\\(.*auth_protocol.*=.*\\)$/#\1/" /etc/sahara/sahara.conf

    # If the apt-get install had failed, do it again so that the configure
    # step can succeed ;)
    if [ ! $aserr -eq 0 ]; then
	maybe_install_packages sahara-common sahara-api sahara-engine
    fi

    sahara-db-manage --config-file /etc/sahara/sahara.conf upgrade head

    mkdir -p /var/log/sahara

    if [ ${APT_HAS_SAHARA} -eq 0 ]; then
        #pkill sahara-all
	pkill sahara-engine
	pkill sahara-api

	sahara-api >>/var/log/sahara/sahara-api.log 2>&1 &
	sahara-engine >>/var/log/sahara/sahara-engine.log 2>&1 &
        #sahara-all >>/var/log/sahara/sahara-all.log 2>&1 &
    else
	service_restart sahara-api
	service_enable sahara-api
	service_restart sahara-engine
	service_enable sahara-engine
    fi

    service_restart apache2
    service_restart memcached

    echo "SAHARA_DBPASS=\"${SAHARA_DBPASS}\"" >> $SETTINGS
    echo "SAHARA_PASS=\"${SAHARA_PASS}\"" >> $SETTINGS
    logtend "sahara"
fi

#
# (Maybe) Install Ironic
#
if [ 0 = 1 -a "$OSCODENAME" = "kilo" -a -n "$BAREMETALNODES" -a -z "${IRONIC_DBPASS}" ]; then
    logtstart "ironic"
    IRONIC_DBPASS=`$PSWDGEN`
    IRONIC_PASS=`$PSWDGEN`

    echo "create database ironic character set utf8" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on ironic.* to 'ironic'@'localhost' identified by '$IRONIC_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"
    echo "grant all privileges on ironic.* to 'ironic'@'%' identified by '$IRONIC_DBPASS'" | mysql -u root --password="$DB_ROOT_PASS"

    keystone user-create --name ironic --pass $IRONIC_PASS
    keystone user-role-add --user ironic --tenant service --role admin

    keystone service-create --name ironic --type baremetal \
	--description "OpenStack Bare Metal Provisioning Service"
    keystone endpoint-create \
	--service-id $(keystone service-list | awk '/ ironic / {print $2}') \
	--publicurl http://${CONTROLLER}:6385 \
	--internalurl http://${CONTROLLER}:6385 \
	--adminurl http://${CONTROLLER}:6385 \
	--region $REGION

    maybe_install_packages ironic-api ironic-conductor python-ironicclient python-ironic

    crudini --set /etc/ironic/ironic.conf \
	database connection "${DBDSTRING}://ironic:${IRONIC_DBPASS}@$CONTROLLER/ironic?charset=utf8"

    if [ $OSVERSION -lt $OSNEWTON ] ; then
	crudini --set /etc/ironic/ironic.conf DEFAULT \
	    rabbit_host $CONTROLLER
	crudini --set /etc/ironic/ironic.conf DEFAULT \
	    rabbit_userid ${RABBIT_USER}
	crudini --set /etc/ironic/ironic.conf DEFAULT \
	    rabbit_password ${RABBIT_PASS}
    else
	crudini --set /etc/ironic/ironic.conf DEFAULT transport_url $RABBIT_URL
    fi

    crudini --set /etc/ironic/ironic.conf DEFAULT verbose ${VERBOSE_LOGGING}
    crudini --set /etc/ironic/ironic.conf DEFAULT debug ${DEBUG_LOGGING}

    crudini --set /etc/ironic/ironic.conf DEFAULT auth_strategy keystone
    crudini --set /etc/ironic/ironic.conf \
	keystone_authtoken auth_uri "http://$CONTROLLER:5000/"
    crudini --set /etc/ironic/ironic.conf \
	keystone_authtoken identity_uri "http://$CONTROLLER:35357"
    crudini --set /etc/ironic/ironic.conf \
	keystone_authtoken admin_user ironic
    crudini --set /etc/ironic/ironic.conf \
	keystone_authtoken admin_password ${IRONIC_PASS}
    crudini --set /etc/ironic/ironic.conf \
	keystone_authtoken admin_tenant_name service

    crudini --del /etc/ironic/ironic.conf keystone_authtoken auth_host
    crudini --del /etc/ironic/ironic.conf keystone_authtoken auth_port
    crudini --del /etc/ironic/ironic.conf keystone_authtoken auth_protocol

    crudini --set /etc/ironic/ironic.conf neutron url "http://$CONTROLLER:9696"

    crudini --set /etc/ironic/ironic.conf glance glance_host $CONTROLLER

    su -s /bin/sh -c "ironic-dbsync --config-file /etc/ironic/ironic.conf create_schema" ironic

    service_restart ironic-api
    service_enable ironic-api
    service_restart ironic-conductor
    service_enable ironic-conductor

    echo "IRONIC_DBPASS=\"${IRONIC_DBPASS}\"" >> $SETTINGS
    echo "IRONIC_PASS=\"${IRONIC_PASS}\"" >> $SETTINGS
    logtend "ironic"
fi

#
# Setup some basic images and networks
#
if [ -z "${SETUP_BASIC_DONE}" ]; then
    $DIRNAME/setup-basic.sh
    echo "SETUP_BASIC_DONE=\"1\"" >> $SETTINGS
fi

#
# Install and startup the slothd-for-openstack idleness detector
#
cp -p $DIRNAME/openstack-slothd.py $OURDIR/
if [ $OSVERSION -ge $OSKILO ]; then
    cat <<EOF >/etc/systemd/system/openstack-slothd.service
[Unit]
Description=Cloudlab OpenStack Resource Usage Collector
After=network.target network-online.target local-fs.target
Wants=network.target
Before=rabbitmq-server.service
Requires=rabbitmq-server.service

[Service]
Type=simple
RemainAfterExit=no
ExecStart=$OURDIR/openstack-slothd.py
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable openstack-slothd.service
    systemctl restart openstack-slothd.service
else
    cat <<EOF >/etc/init/openstack-slothd.conf
# openstack-slothd - Cloudlab OpenStack Resource Usage Collector
#
# openstack-slothd collects OpenStack resource usage statistics

description     "Cloudlab OpenStack slothd"

start on runlevel [2345]
stop on runlevel [!2345]

respawn
respawn limit 10 5
umask 022

expect stop

console none

pre-start script
    test -x /root/setup/openstack-slothd.py || { stop; exit 0; }
end script

exec /root/setup/openstack-slothd.py &
EOF
    service openstack-slothd enable
    service openstack-slothd start
fi

RANDPASSSTRING=""
if [ -e $OURDIR/random_admin_pass ]; then
    RANDPASSSTRING="We generated a random OpenStack admin and instance VM password for you, since one wasn't supplied.  The password is '${ADMIN_PASS}'"
fi

logtstart "ext"
EXTDIRS=`find $DIRNAME/ext -maxdepth 1 -type d | grep -v ^\.\$ | grep -v $DIRNAME/ext\$ | xargs`
if [ ! -z "$EXTDIRS" ]; then
    echo "***"
    echo "*** ALMOST Done with OpenStack Setup -- running extension setup scripts $EXTDIRS !"
    echo "***"
    echo "*** Login to your shiny new cloud at "
    echo "  http://$CONTROLLER.$EEID.$EPID.${OURDOMAIN}/horizon/auth/login/?next=/horizon/project/instances/ !  ${RANDPASSSTRING}"
    echo "***"

    echo "Your OpenStack instance has almost completed setup -- running your extension setup scripts now ($EXTDIRS)!  Browse to http://$CONTROLLER.$EEID.$EPID.${OURDOMAIN}/horizon/auth/login/?next=/horizon/project/instances/ .  ${RANDPASSSTRING}" \
	|  mail -s "OpenStack Instance ALMOST Finished Setting Up" ${SWAPPER_EMAIL}

    for dir in $EXTDIRS ; do
	dirbase=`basename $dir`
	$DIRNAME/ext/$dirbase/setup.sh 1> $OURDIR/setup-ext-$dirbase.log 2>&1 </dev/null
    done
fi
logtend "ext"

echo "***"
echo "*** Done with OpenStack Setup!"
echo "***"
echo "*** Login to your shiny new cloud at "
echo "  http://$CONTROLLER.$EEID.$EPID.${OURDOMAIN}/horizon/auth/login/?next=/horizon/project/instances/ !  ${RANDPASSSTRING}"
echo "***"

echo "Your OpenStack instance has completed setup!  Browse to http://$CONTROLLER.$EEID.$EPID.${OURDOMAIN}/horizon/auth/login/?next=/horizon/project/instances/ .  ${RANDPASSSTRING}" \
    |  mail -s "OpenStack Instance Finished Setting Up" ${SWAPPER_EMAIL}

touch $OURDIR/controller-done

logtend "controller"

exit 0
