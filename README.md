# elasticsearch-cluster-restart
Rolling restart script for elasticsearch 2.x

## Authors:
Ashton Davis (contact@adavis.me)                                                           
## Credits:
This script is a significant expansion upon / rewrite of https://github.com/adamenger/rolypoly

## Purpose:
Gracefully restart an elasticsearch cluster.                                               
## Configuration
For lack of a better solution, this script requires the user to define their environment.

You'll find this section in the top of the script.

Example:
```
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

```
`cluster1` is a hash object, with `name`, `master`, `data`, and `client` arrays.
`name` is required, as is `data`.

`list_of_clusters` is an array of the cluster object names (i.e. `cluster1`, `cluster2`, etc).

This script isn't really necessary for rolling only master / client nodes, as it does balancing that client / master nodes don't need.  The script assumes you're rolling data nodes.


## Usage:
##### Execution
```
/path/to/ruby es_rolling_restart.rb
```
The script is interactive.  I plan to add a non-interactive mode someday.

##### Authentication
This script will use your username and your default ssh settings.
By default it will use your private key.  I don't recommend doing this with passwords.

## License:
Apache License v2.0 -- http://www.apache.org/licenses/LICENSE-2.0

This script is provided as-is, with no implicit or explicit warranty. Use at your own discretion.
## Requirements:
##### OS:
- \*nix (requires native ssh client)

##### RUBY:
- 2.x

##### GEMS:
- elasticsearch
- elasticsearch-api
- elasticsearch-transport
- httparty
- colorize


## Notes on development:
I mean to add username and private key options - just haven't gotten there yet.

## Contribution:
Issues are welcome, PRs are highly encouraged.  Contribute away!
