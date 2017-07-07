#!/bin/bash

set -ex

# set env
export DEBIAN_FRONTEND=noninteractive

# adding backport (openjdk)
echo "deb http://ftp.de.debian.org/debian jessie-backports main" > /etc/apt/sources.list.d/backports.list

# updating package list
apt-get update

# install dependencies
apt-get --no-install-recommends -y install apt-transport-https libterm-readline-perl-perl locales mc net-tools nginx

# install postfix
echo "postfix postfix/main_mailer_type string Internet site" > preseed.txt
debconf-set-selections preseed.txt
apt-get --no-install-recommends install -q -y postfix

# install postgresql server
locale-gen en_US.UTF-8
localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
echo "LANG=en_US.UTF-8" > /etc/default/locale
apt-get --no-install-recommends install -q -y postgresql

# updating package list again
apt-get update

# create zammad user
useradd -M -d "${ZAMMAD_DIR}" -s /bin/bash zammad

# git clone zammad
cd "$(dirname "${ZAMMAD_DIR}")"
git clone "${GIT_URL}"

# switch to git branch
cd "${ZAMMAD_DIR}"
git checkout "${GIT_BRANCH}"

# install zammad
if [ "${RAILS_ENV}" == "production" ]; then
  bundle install --without test development mysql
elif [ "${RAILS_ENV}" == "development" ]; then
  bundle install --without mysql
fi

# fetch locales
contrib/packager.io/fetch_locales.rb

# create db & user
ZAMMAD_DB_PASS="$(tr -dc A-Za-z0-9 < /dev/urandom | head -c10)"
su - postgres -c "createdb -E UTF8 ${ZAMMAD_DB}"
echo "CREATE USER \"${ZAMMAD_DB_USER}\" WITH PASSWORD '${ZAMMAD_DB_PASS}';" | su - postgres -c psql
echo "GRANT ALL PRIVILEGES ON DATABASE \"${ZAMMAD_DB}\" TO \"${ZAMMAD_DB_USER}\";" | su - postgres -c psql

# create database.yml
sed -e "s#production:#${RAILS_ENV}:#" -e "s#.*adapter:.*#  adapter: postgresql#" -e "s#.*username:.*#  username: ${ZAMMAD_DB_USER}#" -e "s#.*password:.*#  password: ${ZAMMAD_DB_PASS}#" -e "s#.*database:.*#  database: ${ZAMMAD_DB}\n  host: localhost#" < ${ZAMMAD_DIR}/config/database.yml.pkgr > ${ZAMMAD_DIR}/config/database.yml

# populate database
bundle exec rake db:migrate
bundle exec rake db:seed

# assets precompile
bundle exec rake assets:precompile

# delete assets precompile cache
rm -r tmp/cache

# create es searchindex
bundle exec rails r "Setting.set('es_url', 'http://elasticsearch:9200')"
bundle exec rake searchindex:rebuild

# copy nginx zammad config
cp ${ZAMMAD_DIR}/contrib/nginx/zammad.conf /etc/nginx/sites-enabled/zammad.conf

# set user & group to zammad
chown -R zammad:zammad "${ZAMMAD_DIR}"
