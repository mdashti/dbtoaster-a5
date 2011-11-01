#!/bin/bash

if [ $# -ne 4 ]; then
  echo "Usage: $0 <timeout> <query template dir> <output dir> <data dir>"
  exit 1
fi

timeout=$1
query_template_dir=$2
output_dir=$3
data_dir=$4

working_dir=`pwd`
script_dir=/local/dbt_stream_experiments/experiments/streams/streambase/scripts

queries=`ls -1 $query_template_dir/*.ssql | sed 's/.ssql//'`

for i in 0; do
  # Prepare query files in a new run dir
  run_dir="$output_dir/run$i"
  test -d $run_dir || (echo "Creating run output: $run_dir" && mkdir -p $run_dir)
  
  echo "Linking dataset..."
  ln -s $data_dir $run_dir/data

  for q in $queries; do
    query=`basename $q`
    if [ -f $query_template_dir/"$query".ssql ]; then
      echo "Generating $query.ssql..."
      sed "s/@@PATH@@/data\//" < $query_template_dir/"$query".ssql \
        > $run_dir/"$query".ssql
    
      # Run the SPE on this query.
      cd $run_dir
      echo "Running SPE on $query"
      $script_dir/run_spe.py -t $timeout $query

      # wait a bit to ensure the socket is freed after terminating the SPE
      sleep 20
      cd $working_dir
    fi
  done
done