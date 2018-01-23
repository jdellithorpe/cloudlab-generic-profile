#!/bin/bash
# Script for setting up software development environment for a specific user.

# Get the absolute path of this script on the system.
SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"

# RC server partition that will be used for RAMCloud backups.
RCXX_BACKUP_DIR=$1

# Checkout TorcDB, RAMCloud, and related repositories
echo -e "\n===== CLONING REPOSITORIES ====="
git clone https://github.com/jdellithorpe/RAMCloud.git
git clone https://github.com/PlatformLab/TorcDB.git
git clone https://github.com/ldbc/ldbc_snb_driver.git
git clone https://github.com/PlatformLab/ldbc-snb-impls.git
git clone https://github.com/jdellithorpe/ldbc-snb-tools.git
git clone https://github.com/jdellithorpe/RAMCloudUtils.git
git clone https://github.com/apache/tinkerpop.git
git clone https://github.com/jdellithorpe/config.git

# Compile and configure RAMCloud
echo -e "\n===== COMPILE AND CONFIGURE RAMCLOUD ====="
cd RAMCloud
git submodule update --init --recursive
ln -s ../../hooks/pre-commit .git/hooks/pre-commit
git checkout java-transactions

# Generate private makefile configuration
mkdir private
cat >>private/MakefragPrivateTop <<EOL
DEBUG := no

CCACHE := yes
LINKER := gold
DEBUG_OPT := yes

GLIBCXX_USE_CXX11_ABI := yes

DPDK := yes
DPDK_DIR := dpdk
DPDK_SHARED := no
EOL

MLNX_DPDK=y scripts/dpdkBuild.sh

# Build DPDK libraries
#hardware_type=$(geni-get manifest | grep -oP 'hardware_type="\K[^"]*' | head -1)
#if [ "$hardware_type" = "m510" ]; then
#    MLNX_DPDK=y scripts/dpdkBuild.sh
#elif [ "$hardware_type" = "d430" ]; then
#    scripts/dpdkBuild.sh
#fi

make -j8

# Add path to libramcloud.so to dynamic library search path
cat >> $HOME/.bashrc <<EOM

export LD_LIBRARY_PATH=$HOME/RAMCloud/obj.java-transactions
EOM

cd bindings/java
echo -e "\n===== COMPILE AND CONFIGURE RAMCLOUD JAVA BINDINGS ====="
./gradlew

mvn install:install-file -Dfile=$HOME/RAMCloud/bindings/java/build/libs/ramcloud.jar -DgroupId=edu.stanford -DartifactId=ramcloud -Dversion=1.0 -Dpackaging=jar

# Construct localconfig.py for this cluster setup.
cd $HOME/RAMCloud/scripts
> localconfig.py

# Set the backup file location
echo "default_disk1 = '-f $RCXX_BACKUP_DIR/backup.log'" >> localconfig.py

# Construct localconfig hosts array
echo -e "\n===== SETUP RAMCLOUD LOCALCONFIG.PY ====="
while read -r ip hostname alias1 alias2 alias3
do 
  if [[ $hostname =~ ^rc[0-9]+-ctrl$ ]] 
  then
    rcnames=("${rcnames[@]}" "$hostname") 
  fi 
done < /etc/hosts
IFS=$'\n' rcnames=($(sort <<<"${rcnames[*]}"))
unset IFS

echo -n "hosts = [" >> localconfig.py
for i in $(seq ${#rcnames[@]})
do
  hostname=${rcnames[$(( i - 1 ))]}
  ipaddress=`getent hosts $hostname | awk '{ print $1 }'`
#  ipaddress=`ssh $hostname "hostname -i"`
  tuplestr="(\"$hostname\", \"$ipaddress\", $i)"
  if [[ $i == ${#rcnames[@]} ]]
  then
    echo "$tuplestr]" >> localconfig.py
  else 
    echo -n "$tuplestr, " >> localconfig.py
  fi
done

# Build TorcDB
echo -e "\n===== BUILD TORCDB ====="
cd $HOME/TorcDB
git checkout ldbc-snb-optimized
mvn install -DskipTests

# Build the LDBC SNB driver
echo -e "\n===== BUILD LDBC SNB DRIVER ====="
cd $HOME/ldbc_snb_driver
mvn install -DskipTests

# Configure the LDBC SNB driver
cp -R /local/repository/ldbc_snb_driver.conf/configuration $HOME/ldbc_snb_driver/

# Build the LDBC SNB implementation for TorcDB
echo -e "\n===== BUILD LDBC SNB IMPLS ====="
cd $HOME/ldbc-snb-impls
mvn install -DskipTests
cd snb-interactive-torc
mvn compile assembly:single

# Build the gremlin-console for TinkerPop
echo -e "\n===== BUILD GREMLIN CONSOLE ====="
cd $HOME/tinkerpop/gremlin-console
mvn install -DskipTests

cd $HOME/ldbc-snb-impls
cp snb-interactive-torc/target/*.jar $HOME/tinkerpop/gremlin-console/target/apache-tinkerpop-gremlin-console-3.3.1-SNAPSHOT-standalone/lib
cp snb-interactive-tools/target/*.jar $HOME/tinkerpop/gremlin-console/target/apache-tinkerpop-gremlin-console-3.3.1-SNAPSHOT-standalone/lib
cp snb-interactive-core/target/*.jar $HOME/tinkerpop/gremlin-console/target/apache-tinkerpop-gremlin-console-3.3.1-SNAPSHOT-standalone/lib
cp snb-interactive-torc/scripts/ExampleGremlinSetup.sh $HOME/tinkerpop/gremlin-console/target/apache-tinkerpop-gremlin-console-3.3.1-SNAPSHOT-standalone

# Configure the machine with my personal settings
echo -e "\n===== SETUP USER CONFIG SETTINGS ====="
cd $HOME/config
./cloudlab/setup.sh
