#!/usr/bin/ruby
#########################
# es_rolling_restart.rb #
#########################
# Authors: Ashton Davis (contact@adavis.me)                                                           
#   - a significant expansion upon / rewrite of https://github.com/adamenger/rolypoly                 
###
# Purpose: Gracefully restart an elasticsearch cluster.                                               
###
# License: Apache License v2.0 -- http://www.apache.org/licenses/LICENSE-2.0
# This script is provided as-is, with no implicit or explicit warranty.
# Use at your own discretion.
###
# Requirements:
#   OS:
#     - Linux
#   RUBY:
#     - 2.x
#   GEMS:
#     - elasticsearch
#     - elasticsearch-api
#     - elasticsearch-transport
#     - httparty
#     - colorize
###
# Notes on usage: This script will use your username and your default ssh settings.
# By default it will use your private key.  I don't recommend doing this with passwords.
###
# Notes on development: I mean to add username and private key options - just haven't gotten there yet.
###
# Contribution: Feel free to fork and submit PRs - I'm 100% for making this script better.
############
# INCLUDES #
############
# Gems
require 'elasticsearch'
require 'httparty'
require 'colorize'
# Built-in
require 'socket'
require 'net/ssh'
#
###############
# HOST GROUPS #
###############
# Format: 
# var_name = {
#   name => 'string',
#   master => [ 'array', 'of', 'masters' ],
#   data => [ 'array', 'of', 'hosts' ],
#   client => [ 'array', 'of', 'hosts' ]
#   }
#   If all nodes are both master and data, just specify data - but leave the empty arrays.
#   Note: add each new host group to the list_of_clusters array.

# EXAMPLE CLUSTER
cluster1 = {
  'name' => 'Production Cluster',
  'master' => [
    'es-master-01.yourcompany.com',
    'es-master-02.yourcompany.com',
    'es-master-03.yourcompany.com'
  ],
  'data' => [
    'es-data-01.yourcomany.com',
    'es-data-02.yourcomany.com',
    'es-data-03.yourcomany.com',
    'es-data-04.yourcomany.com',
    'es-data-05.yourcomany.com'
  ],
  'client' => [
    'es-client-01.yourcompany.com'
  ]
}

list_of_clusters = [ cluster1 ]

logfile = "/tmp/rolypoly_progress"

# END CONFIGURATION SECTION

# Start the clock!
start_time = Time.now.to_i

# Check to make sure sync_id is present 
# AND that replica shards match the primary's sync_id
def check_sync_id(node)
  # Create an empty array
  $to_sync = []
  # Hash containing Sync IDs. Format: 
  # { index: { shard: { primary: $val, replicas: [ $val, $val ] } } }
  sync_ids = Hash.new
  # Create client object
  client = Elasticsearch::Client.new(host: node)
  # List of indices via cat api
  myindices = client.cat.indices h: 'i'
  # create array from string, split on newline
  myindices = myindices.split("\n")
  puts 'Checking sync ids'
  # For each index...
  myindices.each do |index|
    # Strip whitespace
    index = index.strip
    # Create a hash for this index to contain shards and their sync ids
    sync_ids[index] = Hash.new
    #puts "Data for index '#{index}'"
    # create object with index data
    stats = client.indices.stats index: index, level: 'shards'
    # For each shard id...
    stats['indices'][index]['shards'].each_key do |shardid|
      #puts "Data for shard #{shardid}"
      # Create the shardid hash to contain sync ids
      sync_ids[index][shardid] = Hash.new
      # This is my hacked way of getting the array id for reporting.
      iter = 0
      # Create an array for replica ids
      sync_ids[index][shardid]['replicas'] = Array.new
      # Each shard id contains an array of shards.  For each one...
      stats['indices'][index]['shards'][shardid].each do |shard|
        #puts "Stats for shard #{shardid}:#{iter}"
        # This object contains the sync_id for this particular shard.
        sync_id_obj = shard['commit']['user_data']['sync_id']
        # If the shard has no sync_id, mark it
        if sync_id_obj.nil?
          #puts "INDEX: #{index} SHARD: #{shardid}:#{iter} - missing sync_id!"
          $to_sync.push(index)
        elsif shard['routing']['primary'] == true
          #puts "#{index} primary shard sync_id = #{sync_id_obj}"
          sync_ids[index][shardid]['primary'] = sync_id_obj
        else 
          sync_ids[index][shardid]['replicas'].push(sync_id_obj)
        end
          iter = iter + 1
        # Now we check for ID consistency.
      end
      sync_ids[index][shardid]['replicas'].each do |replica|
        primary = sync_ids[index][shardid]['primary']
        # If the replica's sync ID doesn't match the primary shard's sync id...
        if replica != primary
            puts "      |- Mismatch on index #{index} shard #{shardid}".red
            puts "      |- Primary: #{primary}  Replica: #{replica}".red
            # Add this index to the list of indices that need to be flushed.
            $to_sync.push(index)
        end
      end
    end
  end
  if $to_sync.any?
    puts "   |- Indices that need syncing:".yellow
    puts "      |- #{$to_sync.uniq}"
  end
end

def get_relocating_shards(client)
  if client.cluster.health['relocating_shards'] == 0 && client.cluster.health['status'] == "green" && client.cluster.health['unassigned_shards'] == 0
    return true
  else
    return false
  end
end

def sync_flush(node, index)
  # Send a `$index/_flush/synced` command so shard status is clean for restart
  client = Elasticsearch::Client.new(host: node)
  puts "   |- Executing a sync flush on all indices."
  client.indices.flush_synced(index: "#{index}")
end

def disable_allocation(client)
  # Disable shard allocation so things don't get jumbled
  puts "   |- Disabling shard allocation on the cluster"
  client.cluster.put_settings body: { transient: { 'cluster.routing.allocation.enable' => 'none' } }
end

def enable_allocation(client)
  # Enable shard allocation following successful restart
  puts "   |- Enabling shard allocation on the cluster"
  client.cluster.put_settings body: { transient: { 'cluster.routing.allocation.enable' => 'all' } }
end

def wait_for_relocating_shards(node, client)
  # Sleep for two seconds at a time and recheck shard status
  print "   |- Waiting for shards to settle on #{node} "
  until get_relocating_shards(client) do
    print ". ".red
    sleep 2
  end
    puts ""
end

def restart_node(node)
  # Using SSH, send a service restart call
  current_user = ENV['USER']
  puts "   |- Sending restart request to #{node}..."
  Net::SSH.start("#{node}", current_user) do |ssh|
    ssh.exec!("sudo service elasticsearch-01 restart")
    # It's not necessary to output the service restart, but you can uncomment this if you want to see it.
    # NOTE: Make sure to comment out the line above, or you'll run the restart twice.
    #output = ssh.exec!("sudo service elasticsearch-01 restart")
    #puts output
  end 
  puts "      |- Done.".green
end

def wait_for_http(node)
  # Wait for the node to respond again so we can check status
  puts "   |- Waiting for elasticsearch to accept connections on #{node}:9200"
  until test_http(node) do
    print "."
    sleep 1
  end
end

def test_http(node)
  # Ping port 9200 until it responds.
  response = HTTParty.get("http://#{node}:9200", timeout: 1)
  if response['tagline'] == "You Know, for Search"
    true
  end
  rescue Net::OpenTimeout, Errno::ECONNREFUSED
    sleep 1
    false
end

def file_to_array(file)
  # Open the progress file and load in the nodes that have already been restarted.
  nodelist = [] 
  f = File.open(file)
  if File.exist?(file)
    f.each_line {|line|
      nodelist.push line.chomp
    }
    f.close
  end 
  nodelist
end

def already_done(nodelist, node)
  # Check if this node is in the list of completed nodes.
  if nodelist.nil?
    return false
  elsif nodelist.include?(node)
    return true
  else
    return false
  end 
end

def append_to_file(node, file)
  # Add each node to the end of the log file as they are completed.
  f = File.new(file, 'a')
  f.puts node
  f.close
end 

def delete_file(file)
  # Delete the log file when complete
  File.delete(file)
end

def pick_cluster (clusters)
  # Choose the cluster you wish to restart.
  print "Selection: ".blue
  answer = gets.chomp.to_i
  if answer == 0 then pick_cluster # 'a string'.to_i results in 0
  else clusters[answer - 1] end
end

def list_clusters (clusters)
  # List the available clusters.
  i = 1
  clusters.each do |cname|
    puts "\t#{i}) #{cname['name']}"
    i = i + 1
  end
end

def print_cluster (cluster)
  # Print masters, if any exist
  if cluster['master'].any?
    cluster['master'].each do |node|
      puts "\t #{node}"
    end
  end
  # Print clients, if any exist
  if cluster['client'].any?
    cluster['client'].each do |node|
      puts "\t #{node}"
    end
  end
  # Print data nodes
  cluster['data'].each do |node|
    puts "\t #{node}"
  end

end


#############
# GET INPUT #
#############

puts "*~*~* ELASTICSEARCH CLUSTER RESTART *~*~*".yellow
puts "Please choose from the following options: ".blue
list_clusters(list_of_clusters)
# Don't go on until we have a valid answer.
until elasticsearch_cluster = pick_cluster(list_of_clusters)
    puts "Invalid selection.  Please try again.".red
end

# Brief on what will happen
puts "This script will run a rolling restart of these hosts:"
print_cluster(elasticsearch_cluster)

print "Is this okay? (y/N): ".blue
# Die if the answer isn't y|Y(es)
unless gets.chomp =~ /^(y|Y)/
  puts "Exiting."
  exit
end

# Look in a file for already-done nodes.
# (for continuing when the script fails mid-roll)
if File.exist?(logfile) 
  previously_run = file_to_array(logfile)
end

#################
# SANITY CHECKS #
#################
# Quickly grab the first host in the array and run some sanity checks.
cluster_rep = elasticsearch_cluster['data'][0]
client = Elasticsearch::Client.new(host: cluster_rep)
# Check for shards in relocation status, die if greater than 0
if client.cluster.health['relocating_shards'] > 0
  puts "Cluster is rebalancing - There are currently #{client.cluster.health['relocating_shards']} shards relocating. Quitting..."
  exit 1
end
# Check for cluster status, die if not green.
if client.cluster.health['status'] != "green"
  puts "Cluster health is not green, discontinuing."
  exit 1
end
# Check for unassigned shards, die if greater than 0
if client.cluster.health['unassigned_shards'] > 0
  puts "There are unassigned shards - please handle that before trying a rolling restart.  Aborting."
  exit 1
end
# Check for sync_id, and if it doesn't exist, sync_flush
check_sync_id(cluster_rep)
if $to_sync.any?
  $to_sync.uniq.each do |index|
    puts "Executing a sync flush on #{index}."
    begin
      client.indices.flush_synced(index: "#{index}")
    rescue
      puts "   |- Failed for #{index} (there are probably active jobs)".red
    else
      puts "   |- Synced #{index}".red
    end
  end
  check_sync_id(cluster_rep)
  if $to_sync.any?
    print "There are still indices that aren't sync'd, would you like to continue? (y/N): ".blue
    if gets.chomp =~ /^(y|Y)/
      puts "Continuing..."
    else 
      puts "Exiting script.".red
      exit 1
    end
  end
else
  puts "No indices need syncing.".green
end

###########
# DO WORK #
###########
## MASTER
# loop through our cluster and restart all master nodes sequentially
if elasticsearch_cluster['master'].any?
  elasticsearch_cluster['master'].each do |node|
    puts "Processing #{node}".yellow
    if !already_done(previously_run, node)
      client = Elasticsearch::Client.new(host: node)
      # Send the restart command
      restart_node(node)
      # Wait for node to shutdown
      puts "   |- Waiting 15s for node to initiate shutdown..."
      sleep 15
      # Wait for the node to come back
      wait_for_http(node)
      # Add it to the log
      append_to_file(node, logfile)
      puts "   |- Complete.  Logging completion.".green
    else 
      # Skip it if it's already been done.
      puts "   |- #{node} is already finished, skipping...".green
    end 
  end
end
## CLIENT
# loop through our cluster and restart all client nodes sequentially
if elasticsearch_cluster['client'].any?
  elasticsearch_cluster['client'].each do |node|
    puts "Processing #{node}".yellow
    if !already_done(previously_run, node)
      client = Elasticsearch::Client.new(host: node)
      # Disable shard allocation
      restart_node(node)
      # Wait for node to shutdown
      puts "   |- Waiting 15s for node to initiate shutdown..."
      # Wait for the node to come back
      sleep 15
      wait_for_http(node)
      # Add it to the log
      append_to_file(node, logfile)
      puts "   |- Complete.  Logging completion.".green
    else 
      # Skip it if it's already been done
      puts "   |- #{node} is already finished, skipping...".green
    end 
  end
end
## DATA
# loop through our cluster and restart all data nodes sequentially
elasticsearch_cluster['data'].each do |node|
  puts "Processing #{node}".yellow
  if !already_done(previously_run, node)
    client = Elasticsearch::Client.new(host: node)
    # Disable shard allocation
    disable_allocation(client)
    # Send the restart command
    restart_node(node)
    # Wait for node to shutdown
    puts "   |- Waiting 15s for node to initiate shutdown..."
    sleep 15
    # Wait for the node to come back
    wait_for_http(node)
    # Reenable shard allocation
    enable_allocation(client)
    # Wait for the shards to settle before moving on
    wait_for_relocating_shards(node, client)
    # Add it to the log
    append_to_file(node, logfile)
    puts "   |- Complete.  Logging completion.".green
  else 
    # Skip it if it's already been done
    puts "   |- #{node} is already finished, skipping...".green
  end 
end

##########
# FINISH #
##########
# Report the total time
puts "Total restart time: #{Time.now.to_i - start_time}s"
# Clear the log file
delete_file(logfile)
