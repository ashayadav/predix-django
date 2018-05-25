#!/bin/sh

set -e

# Prior to running the script, please make sure you have done the following:
#  	1. cf is installed
#  	2. uaac is installed
# This script does the following:
#   1. Creates the following Predix Services: UAA, Asset, ACS, Time Series and Analytics
#   2. Creates a client with the appropriate permissions (scope and authorities)
#   3. Creates users, groups and assigns users to groups

main() {
	# disabling cf trace mode.
	export CF_TRACE=false
	welcome
	checkPrereq
	loginCf
	deployingApp
	createUAA
	getUAAEndpoint
	createClient
	createAsset
	createTimeseries
	# createBlobstore
  updateClient
	createAssetModel
	createUsers
	createGroups
	assignUsersToGroups
	output
}

checkPrereq()
{
  {
    echo ""
    echo "Checking prerequisites ..."
    verifyCommand 'cf -v'
    verifyCommand 'uaac -v'
    echo ""
  }||
  {
    echo sadKitty
  }
}

# Verifies a given command existence
verifyCommand()
{
  x=$($1)
  # echo "x== $x"
  if [[ ${#x} -gt 5 ]];
  then
    echo "OK - $1"
  else
    echoc r "$1 not found!"
    echoc g "Please install: "
    echoc g "\t CF - https://github.com/cloudfoundry/cli"
    echoc g "\t UAAC -https://github.com/cloudfoundry/cf-uaac"
    sadKitty
  fi
}

loginCf()
{
	# read -p "Enter the Org name: " org_name
	# read -p "Enter the Space name: " space_name
	# read -p "Enter the Username: " user_name
	# read -s -p "Enter the Password: " user_password
	echo -e "\n\nLogging into Cloud Foundry..."
	# cf login -a https://api.system.aws-usw02-pr.ice.predix.io -u $user_name -p $user_password -o $org_name -s $space_name || sadKitty
   #cf login -a https://api.system.aws-usw02-pr.ice.predix.io -u student10 -p 'PrediX20!7' -o Predix-Training -s Training5 || sadKitty
}

deployingApp() {
	echo -e "\n"
	read -p "Enter a prefix for the services name: " prefix
	cd ../hello-predix/
	app_name=$prefix-hello-predix
	echo $app_name
	cf push $app_name --random-route || sadKitty
}

createUAA() {
	echo ""
	echo "Creating UAA service..."
	uaaname=$prefix-uaa
	cf create-service predix-uaa Free $uaaname -c '{"adminClientSecret":"admin_secret"}' || sadKitty
	echo ""
	echo "Binding $app_name app to $uaaname..."
	cf bs $app_name $uaaname || sadKitty
}

getUAAEndpoint() {
	  echo ""
	  echo "Getting UAA endpoint..."
	  {
		 	 env_cf_app=$(cf env $app_name)
			 uaa_uri=`echo $env_cf_app | egrep -o '"uri": "https?://[^ ]+"' | sed s/\"uri\":\ // | sed s/\"//g`

			 if [[ $uaa_uri == *"FAILED"* ]];
			 then
			   echo "Unable to find UAA endpoint for you!"
			   sadKitty
			   exit -1
			 fi

			 echo "UAA endpoint: $uaa_uri"
		} ||
	  {
	    sadKitty
	  }
}

createClient() {
	echo ""
	echo "Creating client..."
	uaac target $uaa_uri --skip-ssl-validation && uaac token client get admin -s admin_secret || sadKitty
	echo ""
	clientname=$prefix-client
	uaac client add $clientname -s secret --authorized_grant_types "authorization_code client_credentials password refresh_token" --autoapprove "openid scim.me" --authorities "clients.read clients.write scim.read scim.write" --redirect_uri "http://localhost:5000"
	base64encoded=`echo -n $clientname:secret|base64`
}

createAsset() {
	echo ""
	echo "Creating Asset service..."
	assetname=$prefix-asset
	cf create-service predix-asset Free $assetname -c '{"trustedIssuerIds":["'$uaa_uri'/oauth/token"]}' || sadKitty
	echo ""
	cf bs $app_name $assetname || sadKitty
	asset_zone=`cf env $app_name|grep predix-asset|grep '"oauth-scope": "'|sed s/\"oauth-scope\":\ // |sed s/\"//g|sed 's/ //g'` || sadKitty
	predix_asset_zone_id=`echo $asset_zone|sed s/predix-asset.zones.//g|sed s/.user//g` || sadKitty
}

createTimeseries() {
	echo ""
	echo "Creating Timeseries service..."
	timeseriesname=$prefix-timeseries
	cf create-service predix-timeseries Free $timeseriesname -c '{"trustedIssuerIds":["'$uaa_uri'/oauth/token"]}' || sadKitty
	echo ""
	cf bs $app_name $timeseriesname || sadKitty
	timeseries_zone=`cf env $app_name|grep zone-http-header-value|sed 'n;d'|sed s/\"zone-http-header-value\":\ // |sed s/\"//g |sed s/\,//g|sed 's/ //g'` || sadKitty
}

createBlobstore() {
	echo ""
	echo "Creating Blobstore service..."
	blobstorename=$prefix-blobstore
	cf create-service predix-blobstore Tiered $blobstorename || sadKitty
	echo ""
	cf bs $app_name $blobstorename || sadKitty
}

updateClient() {
	echo ""
	echo "Updating client..."
	# uaac target $uaa_uri --skip-ssl-validation && uaac token client get admin -s admin_secret || sadKitty
	echo ""
  uaac client update $clientname --authorities "clients.read clients.write scim.write scim.read uaa.resource timeseries.zones.$timeseries_zone.query timeseries.zones.$timeseries_zone.user timeseries.zones.$timeseries_zone.ingest $asset_zone" --scope "openid uaa.none" --redirect_uri "http://localhost:5000"
}

createAssetModel() {
	client=$clientname:secret
	auth=$(printf $client | base64)
	sleep 10
	token_uri=$uaa_uri/oauth/token
	tokenJson=`curl "$token_uri" -H 'Pragma: no-cache' -H 'content-type: application/x-www-form-urlencoded' -H 'Cache-Control: no-cache' -H 'authorization: Basic '$auth'' --data 'client_id='$clientname'&grant_type=client_credentials'` || sadKitty
  	echo ""
	echo "Getting Token..."
	token=`echo $tokenJson|egrep -o '"access_token":"[^ ]+","t'|sed s/\"access_token\":\"//|sed s/\",\"t//`

	echo "Ingesting Connected Cars data..."
	sleep 1
	curl 'https://predix-asset.run.aws-usw02-pr.ice.predix.io/connected_car' -X POST -H 'predix-zone-id: '$predix_asset_zone_id'' -H 'authorization: '$token'' -H 'content-type: application/json' --data-binary '[{"uri":"/connected_car/cc1","createdTimestamp":"1499884031000","vin":"1HD1DGL17SY682612","make":"Ford","model":"Fusion","color":"Ingot Silver","odometerMileage":{"value":24532,"unit":"mi"},"fuelTankCapacity":{"value":16.5,"unit":"gal"},"location":"/location/sanramon","lastServiceDate":"06-20-2017","sensors":[{"uri":"/sensor/cc1_outside_temperature","name":"cc1_outside_temperature"},{"uri":"/sensor/cc1_speed","name":"cc1_speed"},{"uri":"/sensor/cc1_parking_brake_status","name":"cc1_parking_brake_status"},{"uri":"/sensor/cc1_gas_cap_status","name":"cc1_gas_cap_status"},{"uri":"/sensor/cc1_window_status","name":"cc1_window_status"},{"uri":"/sensor/cc1_engine_temperature","name":"cc1_engine_temperature"},{"uri":"/sensor/cc1_fuel_level","name":"cc1_fuel_level"},{"uri":"/sensor/cc1_tire_pressure_level","name":"cc1_tire_pressure_level"}]},{"uri":"/connected_car/cc2","createdTimestamp":"1499884031000","vin":"1FTEX1EP8FFA81722","make":"Hyundai","model":"Sonata","color":"Scarlet Red","odometerMileage":{"value":61051,"unit":"mi"},"fuelTankCapacity":{"value":18.5,"unit":"gal"},"location":"/location/chicago","lastServiceDate":"06-20-2017","sensors":[{"uri":"/sensor/cc2_outside_temperature","name":"cc2_outside_temperature"},{"uri":"/sensor/cc2_speed","name":"cc2_speed"},{"uri":"/sensor/cc2_parking_brake_status","name":"cc2_parking_brake_status"},{"uri":"/sensor/cc2_gas_cap_status","name":"cc2_gas_cap_status"},{"uri":"/sensor/cc2_window_status","name":"cc2_window_status"},{"uri":"/sensor/cc2_engine_temperature","name":"cc2_engine_temperature"},{"uri":"/sensor/cc2_fuel_level","name":"cc2_fuel_level"},{"uri":"/sensor/cc2_tire_pressure_level","name":"cc2_tire_pressure_level"}]},{"uri":"/connected_car/cc3","createdTimestamp":"1499884031000","vin":"WAUKFAFLXAA030811","make":"Toyota","model":"Prius","color":"Sea Glass","odometerMileage":{"value":121457,"unit":"mi"},"fuelTankCapacity":{"value":11.3,"unit":"gal"},"location":"/location/newyorkcity","lastServiceDate":"06-20-2017","sensors":[{"uri":"/sensor/cc3_outside_temperature","name":"cc3_outside_temperature"},{"uri":"/sensor/cc3_speed","name":"cc3_speed"},{"uri":"/sensor/cc3_parking_brake_status","name":"cc3_parking_brake_status"},{"uri":"/sensor/cc3_gas_cap_status","name":"cc3_gas_cap_status"},{"uri":"/sensor/cc3_window_status","name":"cc3_window_status"},{"uri":"/sensor/cc3_engine_temperature","name":"cc3_engine_temperature"},{"uri":"/sensor/cc3_fuel_level","name":"cc3_fuel_level"},{"uri":"/sensor/cc3_tire_pressure_level","name":"cc3_tire_pressure_level"}]},{"uri":"/connected_car/cc4","createdTimestamp":"1499884031000","vin":"4VZBN24982C096054","make":"Mercedes-Benz","model":"CLA","color":"Night Black","odometerMileage":{"value":2806,"unit":"mi"},"fuelTankCapacity":{"value":14.8,"unit":"gal"},"location":"/location/austin","lastServiceDate":"06-20-2017","sensors":[{"uri":"/sensor/cc4_outside_temperature","name":"cc4_outside_temperature"},{"uri":"/sensor/cc4_speed","name":"cc4_speed"},{"uri":"/sensor/cc4_parking_brake_status","name":"cc4_parking_brake_status"},{"uri":"/sensor/cc4_gas_cap_status","name":"cc4_gas_cap_status"},{"uri":"/sensor/cc4_window_status","name":"cc4_window_status"},{"uri":"/sensor/cc4_engine_temperature","name":"cc4_engine_temperature"},{"uri":"/sensor/cc4_fuel_level","name":"cc4_fuel_level"},{"uri":"/sensor/cc4_tire_pressure_level","name":"cc4_tire_pressure_level"}]},{"uri":"/connected_car/cc5","createdTimestamp":"1499884031000","vin":"JW6DEL1EXTM076644","make":"Chevrolet","model":"Camaro","color":"Krypton Green","odometerMileage":{"value":39450,"unit":"mi"},"fuelTankCapacity":{"value":19,"unit":"gal"},"location":"/location/miami","lastServiceDate":"06-20-2017","sensors":[{"uri":"/sensor/cc5_outside_temperature","name":"cc5_outside_temperature"},{"uri":"/sensor/cc5_speed","name":"cc5_speed"},{"uri":"/sensor/cc5_parking_brake_status","name":"cc5_parking_brake_status"},{"uri":"/sensor/cc5_gas_cap_status","name":"cc5_gas_cap_status"},{"uri":"/sensor/cc5_window_status","name":"cc5_window_status"},{"uri":"/sensor/cc5_engine_temperature","name":"cc5_engine_temperature"},{"uri":"/sensor/cc5_fuel_level","name":"cc5_fuel_level"},{"uri":"/sensor/cc5_tire_pressure_level","name":"cc5_tire_pressure_level"}]}]' || sadKitty

	sleep 3
	echo "Ingesting Sensor data..."
	curl 'https://predix-asset.run.aws-usw02-pr.ice.predix.io/sensor' -X POST -H 'predix-zone-id: '$predix_asset_zone_id'' -H 'authorization: Bearer '$token'' -H 'content-type: application/json' --data-binary '[{"uri":"/sensor/cc1_outside_temperature","createdTimestamp":"1499884031000","tag":"cc1_outside_temperature","unit":"F"},{"uri":"/sensor/cc1_speed","createdTimestamp":"1499884031000","tag":"cc1_speed","unit":"mph"},{"uri":"/sensor/cc1_parking_brake_status","createdTimestamp":"1499884031000","tag":"cc1_parking_brake_status","unit":""},{"uri":"/sensor/cc1_gas_cap_status","createdTimestamp":"1499884031000","tag":"cc1_gas_cap_status","unit":""},{"uri":"/sensor/cc1_window_status","createdTimestamp":"1499884031000","tag":"cc1_window_status","unit":""},{"uri":"/sensor/cc1_engine_temperature","createdTimestamp":"1499884031000","tag":"cc1_engine_temperature","unit":"F"},{"uri":"/sensor/cc1_fuel_level","createdTimestamp":"1499884031000","tag":"cc1_fuel_level","unit":"%"},{"uri":"/sensor/cc1_tire_pressure_level","createdTimestamp":"1499884031000","tag":"cc1_tire_pressure_level","unit":"%"},{"uri":"/sensor/cc2_outside_temperature","createdTimestamp":"1499884031000","tag":"cc2_outside_temperature","unit":"F"},{"uri":"/sensor/cc2_speed","createdTimestamp":"1499884031000","tag":"cc2_speed","unit":"mph"},{"uri":"/sensor/cc2_parking_brake_status","createdTimestamp":"1499884031000","tag":"cc2_parking_brake_status","unit":""},{"uri":"/sensor/cc2_gas_cap_status","createdTimestamp":"1499884031000","tag":"cc2_gas_cap_status","unit":""},{"uri":"/sensor/cc2_window_status","createdTimestamp":"1499884031000","tag":"cc2_window_status","unit":""},{"uri":"/sensor/cc2_engine_temperature","createdTimestamp":"1499884031000","tag":"cc2_engine_temperature","unit":"F"},{"uri":"/sensor/cc2_fuel_level","createdTimestamp":"1499884031000","tag":"cc2_fuel_level","unit":"%"},{"uri":"/sensor/cc2_tire_pressure_level","createdTimestamp":"1499884031000","tag":"cc2_tire_pressure_level","unit":"%"},{"uri":"/sensor/cc3_outside_temperature","createdTimestamp":"1499884031000","tag":"cc3_outside_temperature","unit":"F"},{"uri":"/sensor/cc3_speed","createdTimestamp":"1499884031000","tag":"cc3_speed","unit":"mph"},{"uri":"/sensor/cc3_parking_brake_status","createdTimestamp":"1499884031000","tag":"cc3_parking_brake_status","unit":""},{"uri":"/sensor/cc3_gas_cap_status","createdTimestamp":"1499884031000","tag":"cc3_gas_cap_status","unit":""},{"uri":"/sensor/cc3_window_status","createdTimestamp":"1499884031000","tag":"cc3_window_status","unit":""},{"uri":"/sensor/cc3_engine_temperature","createdTimestamp":"1499884031000","tag":"cc3_engine_temperature","unit":"F"},{"uri":"/sensor/cc3_fuel_level","createdTimestamp":"1499884031000","tag":"cc3_fuel_level","unit":"%"},{"uri":"/sensor/cc3_tire_pressure_level","createdTimestamp":"1499884031000","tag":"cc3_tire_pressure_level","unit":"%"},{"uri":"/sensor/cc4_outside_temperature","createdTimestamp":"1499884031000","tag":"cc4_outside_temperature","unit":"F"},{"uri":"/sensor/cc4_speed","createdTimestamp":"1499884031000","tag":"cc4_speed","unit":"mph"},{"uri":"/sensor/cc4_parking_brake_status","createdTimestamp":"1499884031000","tag":"cc4_parking_brake_status","unit":""},{"uri":"/sensor/cc4_gas_cap_status","createdTimestamp":"1499884031000","tag":"cc4_gas_cap_status","unit":""},{"uri":"/sensor/cc4_window_status","createdTimestamp":"1499884031000","tag":"cc4_window_status","unit":""},{"uri":"/sensor/cc4_engine_temperature","createdTimestamp":"1499884031000","tag":"cc4_engine_temperature","unit":"F"},{"uri":"/sensor/cc4_fuel_level","createdTimestamp":"1499884031000","tag":"cc4_fuel_level","unit":"%"},{"uri":"/sensor/cc4_tire_pressure_level","createdTimestamp":"1499884031000","tag":"cc4_tire_pressure_level","unit":"%"},{"uri":"/sensor/cc5_outside_temperature","createdTimestamp":"1499884031000","tag":"cc5_outside_temperature","unit":"F"},{"uri":"/sensor/cc5_speed","createdTimestamp":"1499884031000","tag":"cc5_speed","unit":"mph"},{"uri":"/sensor/cc5_parking_brake_status","createdTimestamp":"1499884031000","tag":"cc5_parking_brake_status","unit":""},{"uri":"/sensor/cc5_gas_cap_status","createdTimestamp":"1499884031000","tag":"cc5_gas_cap_status","unit":""},{"uri":"/sensor/cc5_window_status","createdTimestamp":"1499884031000","tag":"cc5_window_status","unit":""},{"uri":"/sensor/cc5_engine_temperature","createdTimestamp":"1499884031000","tag":"cc5_engine_temperature","unit":"F"},{"uri":"/sensor/cc5_fuel_level","createdTimestamp":"1499884031000","tag":"cc5_fuel_level","unit":"%"},{"uri":"/sensor/cc5_tire_pressure_level","createdTimestamp":"1499884031000","tag":"cc5_tire_pressure_level","unit":"%"}]' || sadKitty

	sleep 3
	echo "Ingesting Location data..."
	curl 'https://predix-asset.run.aws-usw02-pr.ice.predix.io/location' -X POST -H 'predix-zone-id: '$predix_asset_zone_id'' -H 'authorization: Bearer '$token'' -H 'content-type: application/json' --data-binary '[{"uri":"/location/sanramon","createdTimestamp":"1499884031000","city":"San Ramon","latitude":37.7799,"longitude":-121.978},{"uri":"/location/chicago","createdTimestamp":"1499884031000","city":"Chicago","latitude":41.8781,"longitude":-87.6298},{"uri":"/location/newyorkcity","createdTimestamp":"1499884031000","city":"New York City","latitude":40.7128,"longitude":-74.0059},{"uri":"/location/austin","createdTimestamp":"1499884031000","city":"Austin","latitude":30.2672,"longitude":-97.7431},{"uri":"/location/miami","createdTimestamp":"1499884031000","city":"Miami","latitude":25.7617,"longitude":-80.1918}]' || sadKitty

	sleep 3
	echo "Ingesting Fleet data..."
	curl 'https://predix-asset.run.aws-usw02-pr.ice.predix.io/fleet' -X POST -H 'predix-zone-id: '$predix_asset_zone_id'' -H 'authorization: Bearer '$token'' -H 'content-type: application/json' --data-binary '[{"uri":"/fleet/usa_fleet","createdTimestamp":"1499884031000","connectedCars":[{"uri":"/connected_car/cc1","name":"Ford Fusion"},{"uri":"/connected_car/cc2","name":"Hyundai Sonata"},{"uri":"/connected_car/cc3","name":"Toyota Prius"},{"uri":"/connected_car/cc4","name":"Mercedes-Benz CLA"},{"uri":"/connected_car/cc5","name":"Chevrolet Camaro"}]}]' || sadKitty

	echo "Asset model created"
}

createUsers() {
	echo ""
	echo "Creating users..."
	uaac user add app_admin --emails app_admin@gegrctest.com -p APP_admin18 || sadKitty
	uaac user add app_user --emails app_user@gegrctest.com -p APP_user18 || sadKitty
}

createGroups() {
	echo ""
	echo "Creating groups..."
	uaac group add "$asset_zone"
	uaac group add "timeseries.zones.$timeseries_zone.user"
	uaac group add "timeseries.zones.$timeseries_zone.query"
	uaac group add "timeseries.zones.$timeseries_zone.ingest"
}

assignUsersToGroups() {
	echo ""
	echo "Assigning users to groups..."
	uaac member add "$asset_zone" app_admin
	uaac member add "timeseries.zones.$timeseries_zone.user" app_admin
	uaac member add "timeseries.zones.$timeseries_zone.query" app_admin
	uaac member add "timeseries.zones.$timeseries_zone.ingest" app_admin

	uaac member add "$asset_zone" app_user
	uaac member add "timeseries.zones.$timeseries_zone.user" app_user
	uaac member add "timeseries.zones.$timeseries_zone.query" app_user
	uaac member add "timeseries.zones.$timeseries_zone.ingest" app_user
}

############################### ASCII ART ###############################
# Predix Training
welcome()
{
	cat <<"EOT"
   _____                 _  _     _______           _         _
  |  __ \               | |(_)   |__   __|         (_)       (_)
  | |__) |_ __  ___   __| | _ __  __| | _ __  __ _  _  _ __   _  _ __    __ _
  |  ___/| '__|/ _ \ / _` || |\ \/ /| || '__|/ _` || || '_ \ | || '_ \  / _` |
  | |    | |  |  __/| (_| || | >  < | || |  | (_| || || | | || || | | || (_| |
  |_|    |_|   \___| \__,_||_|/_/\_\|_||_|   \__,_||_||_| |_||_||_| |_| \__, |
                                                                         __/ |
                                                                        |___/

EOT
}

# sad kitty
sadKitty()
{
    cat <<"EOT"

    /\ ___ /\
   (  o   o  )
    \  >#<  /
    /       \
   /         \       ^
  |           |     //
   \         /    //
    ///  ///   --

EOT
echo ""
exit 1
}

output()
{
  cd ../scripts
  cat <<EOF >./adbp-environment.txt
Hello Predix App Name      :  "$app_name"
UAA Name                   :  "$uaaname"
UAA URI                    :  "$uaa_uri"
UAA Admin Secret           :  admin_secret
Client Name                :  "$clientname"
Client Secret              :  secret
Base64ClientCredential	   :  "$base64encoded"
Asset Name                 :  "$assetname"
Asset Zone Id		   :  "$predix_asset_zone_id"
Timeseries Name            :  "$timeseriesname"
Timeseries Zone Id	   :  "$timeseries_zone"
Blobstore Name             :  "$blobstorename"
App Admin User Name        :  app_admin
App Admin User Password    :  APP_admin18
App User Name              :  app_user
App User Password          :  APP_user18
EOF
 echo ""
 echo "Your services are now set up!"
 echo "An adbp-environment.txt file with all your environment details is created in the scripts directory"
}

main "$@"
