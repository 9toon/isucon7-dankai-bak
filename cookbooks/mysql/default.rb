service 'mysql'

%w(
  /etc/mysql/my.cnf
  /etc/mysql/mysql.cnf
  /etc/mysql/conf.d/mysql.cnf
  /etc/mysql/conf.d/mysqldump.cnf
  /etc/mysql/mysql.conf.d/mysqld.cnf
  /etc/mysql/mysql.conf.d/mysqld_safe_syslog.cnf
).each do |file|
  remote_file file do
    owner 'root'
    group 'root'
    mode '644'
    notifies :restart, 'service[mysql]'
  end
end
