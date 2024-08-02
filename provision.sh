#!/bin/bash
set -e  # Exit immediately if a command exits with a non-zero status.
set -u  # Treat unset variables as an error when substituting.
set -v  # Print shell input lines as they are read.
set -x  # Print commands and their arguments as they are executed.

# ставим необходимые пакеты:
sudo dnf install --assumeyes rpmdevtools createrepo

# меняем версию nginx, на последнюю имеющиюся:
sudo dnf --assumeyes module enable nginx:1.24
# устанавливаем необходимые для сборки nginx зависимости:
sudo dnf --assumeyes builddep nginx

# скачиваем и устанавливаем исходиники nginx:
dnf download --source nginx
rpm -i nginx-1.24.*.src.rpm

# скачиваем версию 1.27 nginx:
curl --output rpmbuild/SOURCES/nginx-1.27.0.tar.gz \
  https://nginx.org/download/nginx-1.27.0.tar.gz
curl --output rpmbuild/SOURCES/nginx-1.27.0.tar.gz.asc \
  https://nginx.org/download/nginx-1.27.0.tar.gz.asc

# скачиваем nginx-module-vts:
curl --output rpmbuild/SOURCES/nginx-module-vts.tar.gz --location \
  https://github.com/vozlt/nginx-module-vts/archive/refs/tags/v0.2.2.tar.gz

# скачиваем новые ключи для исходников nginx:
curl --output rpmbuild/SOURCES/arut.key https://nginx.org/keys/arut.key
curl --output rpmbuild/SOURCES/pluknet.key https://nginx.org/keys/pluknet.key

# обновляем версию nginx и ключи в спецификации:
sed \
  -e 's|^\(Version:\s\+\).\+|\11.27.0|' \
  -e 's|^\(Release:\s\+\).\+|\11%{?dist}.abe|' \
  -e 's|\bmaxim\.key|arut.key|' -i rpmbuild/SPECS/nginx.spec \
  -e 's|\bmdounin\.key|pluknet.key|' \
  -i rpmbuild/SPECS/nginx.spec

# обновляем патч 0005-Init-openssl-engine-properly.patch:
sed \
  -e 's|^index 270b200..f813458|index 8d1f569..92a44a5|' \
  -e 's|^@@ -798,16 +798,24 @@|@@ -771,14 +771,22 @@|' \
  -e '/\*last++/,+1d' \
  -i rpmbuild/SOURCES/0005-Init-openssl-engine-properly.patch

# отключаем часть патчей в спецификации:
sed 's|^\(Patch[567]\)|#\1|' -i rpmbuild/SPECS/nginx.spec

# добавляем nginx-module-vts в спецификацию:
sed \
  -e '/^Source210:/a Source300:         nginx-module-vts.tar.gz' \
  -e '/^%autosetup -p1/a tar -xzof %{SOURCE300}' \
  -e '/configure \\/a \    --add-module=nginx-module-vts \\' \
  -i rpmbuild/SPECS/nginx.spec
sed '/^tar -xzof %{SOURCE300}/a mv nginx-module-vts* nginx-module-vts' \
  -i rpmbuild/SPECS/nginx.spec

# включаем nginx-module-vts в конфигурации:
sed '/^http {/a \    vhost_traffic_status_zone;' \
  -i rpmbuild/SOURCES/nginx.conf
sed '/^        location = \/50x.html {/r'<(
  echo "        }"
  echo ""
  echo "        location /metrics {"
  echo "            vhost_traffic_status_display;"
  echo "            vhost_traffic_status_display_format prometheus;"
  echo "        }"
  echo ""
  echo "        location /status {"
  echo "            vhost_traffic_status_display;"
  echo "            vhost_traffic_status_display_format html;"
) -i rpmbuild/SOURCES/nginx.conf

# обновляем changelog:
sed '/^%changelog/r'<(
  echo "* Fri Aug 02 2024 ABEgorov - 1:1.27.0-1"
  echo "- new version 1.27.0 with vts module"
  echo ""
) -i rpmbuild/SPECS/nginx.spec

# собираем nginx
rpmbuild -ba rpmbuild/SPECS/nginx.spec

# создаём репозиторий:
sudo mkdir -p /var/www/repo
sudo cp rpmbuild/RPMS/noarch/*.rpm /var/www/repo/
sudo cp rpmbuild/RPMS/x86_64/*.rpm /var/www/repo/
sudo cp rpmbuild/SRPMS/*.rpm /var/www/repo/
sudo createrepo /var/www/repo/

# восстанавливаем SELinux Security Context:
sudo restorecon -R /var/www

# ставим nginx, добавляем репозиторий и запускаем его:
sudo dnf --assumeyes install nginx
cat <<EOF | sudo tee /etc/nginx/default.d/repo.conf
location /repo/ {
    root /var/www;
    autoindex on;
}
EOF
sudo systemctl enable nginx
sudo systemctl start nginx

# добавляем репозиторий:
cat << EOF | sudo tee /etc/yum.repos.d/localhost.repo
[localhost]
name=localhost
baseurl=http://localhost/repo
gpgcheck=0
enabled=1
EOF
sudo dnf makecache

# отключаем модуль и обновляем nginx  из нового репозитория:
sudo dnf --assumeyes module disable nginx
sudo dnf --assumeyes upgrade nginx

echo For test open:
echo - http://localhost:8080/repo/
echo - http://localhost:8080/status
echo - http://localhost:8080/metrics
