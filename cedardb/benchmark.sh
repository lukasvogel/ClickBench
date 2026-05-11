#!/bin/bash -e
export PGHOST="/tmp"
export PGUSER=postgres
export PGDATABASE=postgres
export PARALLEL=48
export RELATION_COLUMN_BLOCKSHIFT=19
#export RELATION_COLUMN_SCANPOLICY=n
sudo apt-get update -y
sudo apt-get install -y postgresql-client

# download dataset
echo "Downloading dataset..."
mkdir -p data
cd data

wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/hits.parquet

cd ..

rm -rf db
mkdir db

# get and configure CedarDB image
echo "Starting CedarDB..."
curl https://get.cedardb.com | bash -s -- -y


# Run CedarDB in the background, store PID to kill it later
./cedar/cedardb --createdb ./db &
export CEDAR_PID=$!

# wait for CedarDB to start
until pg_isready > /dev/null 2>&1; do sleep 1; done

# create table and ingest data
psql -f create.sql 2>&1 | tee load_out.txt

echo "Inserting data..."
echo -n "Load time: "

psql -t -c "\timing" -f load.sql 2>&1 | tee load_out.txt

if grep 'ERROR' load_out.txt
then
    exit 1
fi

echo -n "Data size: "
psql -q -t -c "SELECT pg_total_relation_size('hits');"

echo "running benchmark..."
./run.sh 2>&1 | tee log.txt

cat log.txt | \
    grep -oP 'Time: \d+\.\d+ ms|psql: error' | \
    sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/; s/^.*psql: error.*$/null/' | \
    awk '{ if (i % 3 == 0) { printf "[" }; if ($1 == "null") { printf $1 } else { printf $1 / 1000 }; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

kill $CEDAR_PID
# Wait for CedarDB to be gone
while $(kill -0 $CEDAR_PID 2>/dev/null); do
    sleep 1
done