#!/bin/bash
set -e

# Configuration
HADOOP_VERSION=3.3.6
HIVE_VERSION=3.1.3
JAVA_HOME=/usr/lib/jvm/java-1.8.0-openjdk-amd64
HADOOP_HOME=/usr/local/hadoop
HIVE_HOME=/usr/local/hive
MYSQL_PASS="hivepass"
UBUNTU_USER="ubuntu"
DOWNLOAD_DIR=~/datatrack

echo "☑️ Installing prerequisites..."
sudo apt-get update -y
sudo apt-get install -y openjdk-8-jdk mysql-server net-tools openssh-server wget curl unzip

echo "☑️ Setting up SSH for localhost..."
sudo systemctl enable ssh
sudo systemctl start ssh
[ ! -f ~/.ssh/id_rsa ] && ssh-keygen -t rsa -P "" -f ~/.ssh/id_rsa
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
ssh-keyscan -H localhost >> ~/.ssh/known_hosts

echo "☑️ Creating download directory: $DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"
cd "$DOWNLOAD_DIR"

echo "☑️ Downloading Hadoop..."
if [ ! -f "hadoop-$HADOOP_VERSION.tar.gz" ]; then
  wget https://archive.apache.org/dist/hadoop/common/hadoop-$HADOOP_VERSION/hadoop-$HADOOP_VERSION.tar.gz 
fi
sudo tar -xzf hadoop-$HADOOP_VERSION.tar.gz -C /usr/local/
sudo mv /usr/local/hadoop-$HADOOP_VERSION $HADOOP_HOME
sudo chown -R $UBUNTU_USER:$UBUNTU_USER $HADOOP_HOME

echo "☑️ Downloading Hive..."
if [ ! -f "apache-hive-$HIVE_VERSION-bin.tar.gz" ]; then
  wget https://archive.apache.org/dist/hive/hive-3.1.3/apache-hive-3.1.3-bin.tar.gz
fi
sudo tar -xzf apache-hive-3.1.3-bin.tar.gz -C /usr/local/
sudo mv /usr/local/apache-hive-3.1.3-bin $HIVE_HOME
sudo chown -R $UBUNTU_USER:$UBUNTU_USER $HIVE_HOME

echo "☑️ Downloading MySQL Connector..."
if [ ! -f "mysql-connector-java-8.0.32.tar.gz" ]; then
  wget https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/8.0.33/mysql-connector-j-8.0.33.jar 
fi
tar -xzf mysql-connector-java-8.0.33.tar.gz
cp mysql-connector-java-8.0.33/mysql-connector-java-8.0.33.jar $HIVE_HOME/lib/

echo "☑️ Setting environment variables..."
cat <<EOF >> ~/.bashrc
export JAVA_HOME=$JAVA_HOME
export HADOOP_HOME=$HADOOP_HOME
export HIVE_HOME=$HIVE_HOME
export PATH=\$PATH:\$HADOOP_HOME/bin:\$HADOOP_HOME/sbin:\$HIVE_HOME/bin
export HADOOP_CONF_DIR=\$HADOOP_HOME/etc/hadoop
EOF
source ~/.bashrc

echo "☑️ Configuring Hadoop..."
mkdir -p $HADOOP_HOME/hdfs/{namenode,datanode}
cat > $HADOOP_HOME/etc/hadoop/core-site.xml <<EOF
<configuration>
  <property>
    <name>fs.defaultFS</name>
    <value>hdfs://localhost:9000</value>
  </property>
</configuration>
EOF

cat > $HADOOP_HOME/etc/hadoop/hdfs-site.xml <<EOF
<configuration>
  <property>
    <name>dfs.replication</name>
    <value>1</value>
  </property>
  <property>
    <name>dfs.namenode.name.dir</name>
    <value>file:$HADOOP_HOME/hdfs/namenode</value>
  </property>
  <property>
    <name>dfs.datanode.data.dir</name>
    <value>file:$HADOOP_HOME/hdfs/datanode</value>
  </property>
</configuration>
EOF

cp $HADOOP_HOME/etc/hadoop/mapred-site.xml.template $HADOOP_HOME/etc/hadoop/mapred-site.xml
cat > $HADOOP_HOME/etc/hadoop/mapred-site.xml <<EOF
<configuration>
  <property>
    <name>mapreduce.framework.name</name>
    <value>yarn</value>
  </property>
</configuration>
EOF

cat > $HADOOP_HOME/etc/hadoop/yarn-site.xml <<EOF
<configuration>
  <property>
    <name>yarn.nodemanager.aux-services</name>
    <value>mapreduce_shuffle</value>
  </property>
</configuration>
EOF

echo "☑️ Formatting NameNode..."
$HADOOP_HOME/bin/hdfs namenode -format -force

echo "🚀 Starting Hadoop..."
export HDFS_NAMENODE_USER=$UBUNTU_USER
export HDFS_DATANODE_USER=$UBUNTU_USER
export HDFS_SECONDARYNAMENODE_USER=$UBUNTU_USER
export YARN_RESOURCEMANAGER_USER=$UBUNTU_USER
export YARN_NODEMANAGER_USER=$UBUNTU_USER
$HADOOP_HOME/sbin/start-dfs.sh
$HADOOP_HOME/sbin/start-yarn.sh
sleep 10

echo "☑️ Configuring MySQL..."
sudo systemctl start mysql
sudo mysql -e "CREATE USER IF NOT EXISTS 'hive'@'localhost' IDENTIFIED BY '$MYSQL_PASS';"
sudo mysql -e "CREATE DATABASE IF NOT EXISTS metastore;"
sudo mysql -e "GRANT ALL PRIVILEGES ON metastore.* TO 'hive'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

echo "☑️ Configuring Hive..."
cat > $HIVE_HOME/conf/hive-site.xml <<EOF
<configuration>
  <property>
    <name>javax.jdo.option.ConnectionURL</name>
    <value>jdbc:mysql://localhost/metastore?createDatabaseIfNotExist=true</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionDriverName</name>
    <value>com.mysql.cj.jdbc.Driver</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionUserName</name>
    <value>hive</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionPassword</name>
    <value>$MYSQL_PASS</value>
  </property>
  <property>
    <name>hive.metastore.uris</name>
    <value>thrift://localhost:9083</value>
  </property>
  <property>
    <name>hive.metastore.warehouse.dir</name>
    <value>/user/hive/warehouse</value>
  </property>
</configuration>
EOF

echo "☑️ Initializing Hive schema..."
schematool -initSchema -dbType mysql || true

echo "🚀 Starting Hive services..."
nohup $HIVE_HOME/bin/hive --service metastore > /tmp/metastore.log 2>&1 &
nohup $HIVE_HOME/bin/hive --service hiveserver2 > /tmp/hiveserver2.log 2>&1 &
sleep 15

echo "📁 Creating Hive warehouse directory on HDFS..."
hdfs dfs -mkdir -p /user/hive/warehouse
hdfs dfs -chmod -R 777 /user/hive/warehouse

echo "✅ Setup completed successfully!"
