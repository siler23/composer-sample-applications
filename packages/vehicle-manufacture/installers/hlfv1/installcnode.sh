ME=`basename "$0"`
if [ "${ME}" = "install-hlfv1-latest.sh" ]; then
  echo "Please re-run as >   cat install-hlfv1-latest.sh | bash"
  exit 1
fi
(cat > composer.sh; chmod +x composer.sh; exec bash composer.sh)
#!/bin/bash
set -ev

# Docker stop function
function stop()
{
P1=$(docker ps -q)
if [ "${P1}" != "" ]; then
  echo "Killing all running containers"  &2> /dev/null
  docker kill ${P1}
fi

P2=$(docker ps -aq)
if [ "${P2}" != "" ]; then
  echo "Removing all containers"  &2> /dev/null
  docker rm ${P2} -f
fi
}

if [ "$1" == "stop" ]; then
 echo "Stopping all Docker containers" >&2
 stop
 exit 0
fi

# Get the current directory.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get the full path to this script.
SOURCE="${DIR}/composer.sh"

# Create a work directory for extracting files into.
WORKDIR="$(pwd)/composer-data-latest"
rm -rf "${WORKDIR}" && mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# Find the PAYLOAD: marker in this script.
PAYLOAD_LINE=$(grep -a -n '^PAYLOAD:$' "${SOURCE}" | cut -d ':' -f 1)
echo PAYLOAD_LINE=${PAYLOAD_LINE}

# Find and extract the payload in this script.
PAYLOAD_START=$((PAYLOAD_LINE + 1))
echo PAYLOAD_START=${PAYLOAD_START}
tail -n +${PAYLOAD_START} "${SOURCE}" | tar -xzf -

# Ensure sensible permissions on the extracted files.
find . -type d | xargs chmod a+rx
find . -type f | xargs chmod a+r

# Pull the latest versions of all the Docker images.
docker pull gmoney23/clefplay:0.16.5
docker pull gmoney23/clefcli:0.16.5
docker pull gmoney23/clefrest:0.16.5
docker pull gmoney23/vda
docker pull gmoney23/manufacturing
docker pull gmoney23/car-builder
docker pull gmoney23/nodered:2.0

# stop all the docker containers
stop

# run the fabric-dev-scripts to get a running fabric
./fabric-dev-servers/downloadFabric.sh
./fabric-dev-servers/startFabric.sh

# create a card store on the local file system to be shared by the demo
rm -fr $(pwd)/.vld-card-store  
mkdir $(pwd)/.vld-card-store
chmod 777 $(pwd)/.vld-card-store

# Create the environment variables with the connection profile in.
rm -fr $(pwd)/vldstage
mkdir $(pwd)/vldstage
chmod 777 $(pwd)/vldstage
echo '{
    "name": "hlfv1",
    "description": "Hyperledger Fabric v1.0",
    "type": "hlfv1",
    "timeout": 300,
    "orderers": [
        {
            "url": "grpc://orderer.example.com:7050"
        }
    ],
    "channel": "composerchannel",
    "mspID": "Org1MSP",
    "ca": {"url": "http://ca.org1.example.com:7054", "name": "ca.org1.example.com"},
    "peers": [
        {
            "requestURL": "grpc://peer0.org1.example.com:7051",
            "eventURL": "grpc://peer0.org1.example.com:7053"
        }
    ]
}' > $(pwd)/vldstage/connection.json

# build the PeerAdmin card and import it
docker run \
  --rm \
  --network composer_default \
  -v $(pwd)/.vld-card-store:/home/composer/.composer \
  -v $(pwd)/vldstage:/home/composer/vldstage \
  -v $(pwd)/fabric-dev-servers/fabric-scripts/hlfv1/composer/crypto-config/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp:/home/composer/PeerAdmin \
  gmoney23/clefcli:0.16.5 \
  card create -p vldstage/connection.json -u PeerAdmin -r PeerAdmin -r ChannelAdmin -f /home/composer/vldstage/PeerAdmin.card -c PeerAdmin/signcerts/Admin@org1.example.com-cert.pem -k PeerAdmin/keystore/114aab0e76bf0c78308f89efc4b8c9423e31568da0c340ca187a9b17aa9a4457_sk

docker run \
  --rm \
  --network composer_default \
  -v $(pwd)/.vld-card-store:/home/composer/.composer \
  -v $(pwd)/vldstage:/home/composer/vldstage \
  -v $(pwd)/fabric-dev-servers/fabric-scripts/hlfv1/composer/crypto-config/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp:/home/composer/PeerAdmin \
  gmoney23/clefcli:0.16.5 \
  card import -f /home/composer/vldstage/PeerAdmin.card


# Start playground
docker run \
  -d \
  --network composer_default \
  --name composer \
  -v $(pwd)/.vld-card-store:/home/composer/.composer \
  -p 8080:8080 \
  gmoney23/clefplay:0.16.5

# Wait for playground to start
sleep 5

# Deploy the business network archive.
docker run \
  --rm \
  --network composer_default \
  -v $(pwd)/vehicle-manufacture-network.bna:/home/composer/vehicle-manufacture-network.bna \
  -v $(pwd)/vldstage:/home/composer/vldstage \
  -v $(pwd)/.vld-card-store:/home/composer/.composer \
  gmoney23/clefcli:0.16.5 \
  network deploy -c PeerAdmin@hlfv1 -a vehicle-manufacture-network.bna -A admin -S adminpw -f /home/composer/vldstage/bnaadmin.card

docker run \
  --rm \
  --network composer_default \
  -v $(pwd)/vldstage:/home/composer/vldstage \
  -v $(pwd)/.vld-card-store:/home/composer/.composer \
  gmoney23/clefcli:0.16.5 \
  card import -f /home/composer/vldstage/bnaadmin.card


# Submit the setup transaction.
docker run \
  --rm \
  --network composer_default \
  -v $(pwd)/.vld-card-store:/home/composer/.composer \
  gmoney23/clefcli:0.16.5 \
  transaction submit -c admin@vehicle-manufacture-network -d '{"$class": "org.acme.vehicle_network.SetupDemo"}'

# correct permissions so that node-red can read cardstore and node-sdk can write to client-data
docker exec \
  composer \
  find /home/composer/.composer -name "*" -exec chmod 777 {} \;

# Start the REST server.
docker run \
  -d \
  --network composer_default \
  --name rest \
  -v $(pwd)/.vld-card-store:/home/composer/.composer \
  -e COMPOSER_CARD=admin@vehicle-manufacture-network \
  -e COMPOSER_NAMESPACES=required \
  -p 3000:3000 \
  gmoney23/clefrest:0.16.5

# Wait for the REST server to start and initialize.
sleep 10

# Start Node-RED.
docker run \
  -d \
  --network composer_default \
  --name node-red \
  -v $(pwd)/.vld-card-store:/home/node-red/node_modules/node-red/.composer \
  -e COMPOSER_BASE_URL=http://rest:3000 \
  -v $(pwd)/flows.json:/data/flows.json \
  -p 1880:1880 \
  gmoney23/nodered:2.0

# Install custom nodes
docker exec \
  -e NPM_CONFIG_LOGLEVEL=warn \
  node-red \
  bash -c "cd /data && npm install node-red-contrib-composer@latest"
docker restart node-red

# Wait for Node-RED to start and initialize.
sleep 10

# Start the VDA application.
docker run \
-d \
--network composer_default \
--name vda \
-e COMPOSER_BASE_URL=http://rest:3000 \
-e NODE_RED_BASE_URL=ws://node-red:1880 \
-p 3001:6001 \
gmoney23/vda

# Start the manufacturing application.
docker run \
-d \
--network composer_default \
--name manufacturing \
-e COMPOSER_BASE_URL=http://rest:3000 \
-e NODE_RED_BASE_URL=ws://node-red:1880 \
-p 3002:6001 \
gmoney23/manufacturing

# Start the car-builder application.
docker run \
-d \
--network composer_default \
--name car-builder \
-e NODE_RED_BASE_URL=ws://node-red:1880 \
-p 3003:8100 \
gmoney23/car-builder

# Wait for the applications to start and initialize.
sleep 10

# Open the playground in a web browser.
URLS="http://localhost:8100 http://localhost:6002 http://localhost:6001 http://localhost:8080 http://localhost:3000/explorer/ http://localhost:1880"
case "$(uname)" in
"Darwin") open ${URLS}
          ;;
"Linux")  if [ -n "$BROWSER" ] ; then
	       	        $BROWSER http://localhost:8100 http://localhost:6002 http://localhost:6001 http://localhost:8080 http://localhost:3000/explorer/ http://localhost:1880
	        elif    which x-www-browser > /dev/null ; then
                  nohup x-www-browser ${URLS} < /dev/null > /dev/null 2>&1 &
          elif    which xdg-open > /dev/null ; then
                  for URL in ${URLS} ; do
                          xdg-open ${URL}
	                done
          elif  	which gnome-open > /dev/null ; then
	                gnome-open http://localhost:8100 http://localhost:6002 http://localhost:6001 http://localhost:8080 http://localhost:3000/explorer/ http://localhost:1880
	        else
    	            echo "Could not detect web browser to use - please launch Composer Playground URL using your chosen browser ie: <browser executable name> http://localhost:8080 or set your BROWSER variable to the browser launcher in your PATH"
	        fi
          ;;
*)        echo "Playground not launched - this OS is currently not supported "
          ;;
esac

# Exit; this is required as the payload immediately follows.
exit 0

PAYLOAD:
‹ þ£Z ì=KoIzÚÍL&f²Ù 	rØSe­Ô|‰’,Ã‹p$Ê£Œ-)¤dc`xíbw‘ìq³›é‡dÂÐ%· ¹%ÈqsÍ1Çü‡  Hkîùù¾ztW5›ÉòÌd3d6»«¾úÞ¯*Ò—läÚÛS?P;NB¶å³ø*ßZ}Ÿ®ÝÅ«¯m|¯ï¶jú;>©Õš;kõfc»µ»Û¬7`\}§Õh­‘Ú¬¾ä•D1	YëÛIÄÂùã–=ÿ?ú:ûúw>)ñ«ÿfô©ó?¿ÿÇÿüéÚþýÜ›Pû-2ëÛ(ðß—™?t}•÷ß—í`<	€åýò¯kV}Çª•¯7Ë>3¸s9_§Ê›ð4ŒÜÀ‡q0Ñªoo5jõ½Z³VÑïÖê0Âa‘º“XŒz. É É«ã1 	ƒGq<‰ö«ÕÑtÂB9CZC7%}Ëª
ë­ˆŽ'^ŠTT•tFÕ¨Wå»‹KYÑå0·:õáIÌœïµ¤ÄFpËg²IÒ÷ÜhèŒß:n8!VÕq£˜|ñQÚ#÷’;d ‡lmEAÚìð&0'½q‚%Ù¢È"Ñm 2€AÌ¢–÷'c&>ñ\?†üm¿Ì"¼ ¢XÞÍÆÚöè-Í/öñ‚ùÛ²GÌ~›N’Õ4'°Qàßýò·¼æP?vñ2dvF@§MøS®×0A":ì%[1©¥c9¨ØÀÍ rã œ"sc`‰ÂÜ$ô4‰K)ƒuáÏ9jÂË¦ðÙÑ½TÖ 5æÂ§Ôä²ËÔª^m–i´Ç¯²uÉA6Gò´AÏFl«6‹¶vyÈ&Ìw˜o»Ò¶GÔE»nZ->$]:c××,^{d{îÜŒK¶èYàûÌ®n±qŸ9·lœÐÉŽ…Ž4úýÄÃ¶­Üã‚Tè¶2B¥¢Àp2ü01·Åáq‹¹‚ã`,±mXõ]sƒ‡8Ü!²)
m×ÆFuô&nœÁ»aVñ®¸å{=œÄÃÎnI¬}’–+î€0'4FÃ1ê€ëˆß¡¢õ½À~ëú°v&ð
†Çþ (ï¨‰Ï0DÀç××¦gïÿÛ_ÿÃübmÿîÁ½n§}ø¬cûD9Øgšƒ=ŠU*ýŠœÜH9\‡à£"LˆTÛˆÂ`L¨O\ß]êÐkÐÄýUV3Ã ŽH p1¨C_OúÓ<àÐ"m˜:L<
jB ÚLaò$.]Væád8J!cáF^
ãlE)•îß'Ï@<+u}1¬ŸDÔRqÜ}rFCpî<GTzskþòFcQ»
³7bV;ŠŒ/½9Eša€d­||R?‚Ù@+:ó¨ÍÔÈ‹‰˜êÅ4N"¸×cq29dã@Îï\2?6gò[EÓÅNtçw:òT1Õm’R	ã€Ï†*pc2K \PÀÿ~âzŽ!Äk7d±!‘¢¾#%îÆè3&FIìÆÝ >Îbsí‘H8ÐgWDñ“"Acü˜‚vùC®.ƒO TNSzÈ¯S’® 4À{D/QÃ@s P0h,°Ì‰¶Ï ÕEAG‚a„¢ŽF@šÐ+æD©Bƒk‚ÐXÀ#'ÄÄ³Š$®ñ#;¦hr¸öˆúC&…ËÀP…|Êf-’ DÅ5­ñìiû sˆ{_u/žv_v_?kŸ\µÎ/º‹œú6+BxK#kÄåq€ë)+xi¦,£$sÌÀ/,!œ§NÁóã“×í^ïøÉ	°¾N¿¢ iéÊtÚÅ„´2#”êãrî©çM	Å #}‘N	Ú†©[Ñ„ÙîÀ…±®¯Ó¬qiÐ
Æc¡¬Êª8ºuúâ¤ÓÍØAci/“ “)\,¸ò€+˜§4‰Œ€ ²€«Vl6sk™¢è;Œ‘ø*H`äÈAÍ÷âÕ|¯{Ž_pT‹$ÒO<:‚ùNé„^ºCLC¥<66pâÆ‰iŸË’3Tpåš¹Ggûàß¼)½/Rþ3Û™—÷I9‡µÇÌ’îáµJVS åÒ5ŸXâñîÊõ<2dÀJŽÐ(d3bœh!bT*	cø¥>Ç|B k´ ¡‘ºˆ©³œ‘'ì],]ëã
·:„Ü7´C7“'tŸä­ŽdÞöx•)oâŽÌ±ƒsêæ¶¸)'
Ëg}5øÏÍ©›bâ˜¾e8-d¢ÙŸ;_—Ï}ÎÆýsž¶“²à‘zd€Åû½rËr”SÎÑ2<¿tòRT£%Ý1Î`ï Hˆ±FÀÀYè¡À×š$E¤R„ñ²ã0tÌw‚+ “?ÄîÑ§åWÙêÂ>WcP¾ûg’dC¡çÆ[¥äÅ±Vº»Ô5¢–²Ù.Ó†o¨jpê>F5g™ Ê•Ñ¶Ùé/H÷n-n¨Á3À4E–7PæImôjâà+ÝçÆaJc‰ßç‘œEïziÐ#.Ò
	®¢ä%„W$µ"Žæ¤×Ó%gHG7U®•†ì,Rü ©§";áØ°ö%Ú·á^å{ç¦j×HƒMcEŸFLFpHÔW	Ò–%Ïq1Ö…ï@™Ä"µÆ€Ä3XÏú"»rãM‚KÉ< 9dŒ€½>ÿªóº{Ú>´dœ³µ„&—Ý‹í{R+3	ûmR,/—4ŠA¦ÚÏ´–JkbØ!ë’+,V°ü‡$«!i=ÝT‰ôœ¸$²÷,ñ|ü¼#Rz,VwgG®ÏÑP5L†ªÌTÑ_!žÊ³‰€(¿9ì<……»Ã7Y©§;¶ †‡ß‹¦˜ýÿKÃ/UßB6¨À‘x£	°ÃBµÙs	·#Ý¤Ù½Þ…ˆ„4”Èf>…Ì	¶¢Q]ûPÔXä› LŠ]HÖäª&”]ˆavÃî¯ŽK5†Ò¢:¦Vg7 <wÀì)\ñ:
’»±Eœ„yí+^•ót×Ãj]oc½Ðº^jôDI±‘'ÈÏ:ùõþ
9È~d
Þ+1Y2b»S‰][ôÑ^‚gï	n–Ù~úôô…¹vød•)û!…dccÍUÈD‚u_ã‹ I¼oÊ‹·ÐÒâ«”Õamlk_D¨¹[ä	dóQ.—Éð×ñ¬n¨øQY^$úuz=R2ªGM×qÑ¶çA!ë¹áZg‡ísôzäT:$0 
„OSXÔ›fpÆ|tËB1 ¨t¸+í3­¿!½ô†YÆYX„m(yj¸€]Î#L9ät;‚<‡`?z1ÒlC6“yéËÚTQÜ+“‚5µ{—Qg¹H8¢¦@nAî¯Ò¸»ãÒ|Hà¡kÄ*
¡ûv®*¢ohÞ}Ý»Ñ„“½ƒ|æLÁ°+ò|@A¬Â!ŠtÿâCeq_¸X¨ŸUÇÿ<L5"óþ0çR]6ØbH¤¸	#D!a.±J™<Í³DµžQ­Ž¶4Áboc{:²r†‘-Áí6¦¦/JÌ-0ï¿~ó¯ó‡kkø÷s<Ü`†%Y$'wløÜÓŽ#@vÅµQŽ‹´,9xéB=Æ1ˆ°{tO‹Kë“[kŸL°ÃÂÁ›*²¬ÁˆæNÐ„·¿[¼vÖÖÃ™và;®X=°$?­!‹HÄÛáúòø1™äo>Àé2áA²Ë’ÆWM¹V`ìGKvfìEÙW.±ìôÏeîÓ›\ånÀïïŽu©ÝÈäˆw7äÙGf×œld®ÂéA…³Žs
Y–Ãnˆ5î<Ë/$WÇ'Ï9‘Þ}lûž­&g™_‹1þpAÈ\deqH)ˆp#úìF*}{ñÜÒ)¬ÂoNÎÇæºá3~pÊGnã#óÐÈÉ¹Ú®ÈÉ|Z 8©NÉÜ¹–œ¼\Ls÷näòÖÂÀC‰ñ;Kï)Á0³¥ÿ!‹kFíWÖÝðzg["žã)‹sý‚)6—†yF-"-]-Ï"@Šç8i#“”76Ê2$­sÔc¬Ç¼ËbÙ#êF›)bÜÅ#>e~6¤äUÝ<+šF1[ÚêËYoPû§G²ojx&|‚{Ð³­E~þ[·(´ˆÏã»¹‘Ôß!”°2;«	‹×qóWQ
BŠ)íq è£€~ŽÈr*ÔÊ‹ñ[FïüÍªU?¬ÿüñÞnT5=þ§Ÿþíç¿·¶†šB¤ÕYvT7Jdƒ<çY!ÄûŽ<§%N«'›ä¹8¢OV¬ã€²|T~ðALƒ<è”wbñT!o)Ë®.nîc{‚o·¸G¥ÛÃŠ…0¾‘0‚>æ#&L¦j'A$4†¡8;ìûÕêÕÕ•E9²+†Uy47ª>=>èœô:x¦YN¸ð=”);ågûSµ€H=Šu:¡ÃÉJŸ·”Áƒm’(ÄW4d»‡n?‰~)ôp#S`'"L÷ÊäËvï¸·‰@^ŸuzqN^´»ÝöÉùq§GN»äàôäðøüøô>‘öÉ7äëã“ÃMÂ\¾£ÄÞMB¤ ½"'±ƒ°zÂc¥(¨>½ì„Ø@š?Lp›vˆ‡²x³Þhòû‚ñÜ±ËÝºp¡j©„ßæˆ&¢Ž,vá¥RµŠtvÈaçèø„S*¿âJ`çá†¸µõ+#XŒZp? ½˜oÇ¥uô›âˆ6í£÷±/Î¹Cü!®ò€\Ú¶¸{ìð…5Xò¶~)Eð:TQëæ€¢ÃÁ&LuW¿ÇÆ|“ˆ{ê!pä•v–D°L(€±°Áq0(Ji|Oó“1ÉUS°´8æ)°˜w„…?Õó*~ÃÜÑæ·ÒÝE\P‰ôTœ„2ÉÇÓPúguJ»÷òçŸ¸y#O&&{Õž¡^Þˆ›*e¦@‚}[2»Ï$öò<—ÔG)hÙ~@õ¶¸Ù²º5V+®Ì÷:Iî\Õw±°Nra±¾„µ¹Kð£©Î‹µïøøŒÂâ½ÞÖÉAC›êvž\<mŸƒGgQi¢¹Èœ$/ŠÅ¡±°vHEZX·}v&ÌCh´Ú‡0uYò>Ç£…g¢t©Ê	RÀÐœðå°óì”ôÎ:ÇGÇota§ç_É™Ç'ðç¹ý\Úñ›­üì_¬­áßÏä‘gYßF?f?f7È6ÌèØ%G'B]«œÇÜ+f;Obç_>ÿs0y
ùþ
ÍúkÑÎd‹#S¼ïÅášŸ«¥AâÛÉ€¬sœºâ;NDé	13
 ñö‚áz%ZÁâŸ_R ‚â×ß¦ä1
îH|XG­³ì1©Ì£«òH(xóX¶|vÕUÅg
m“T*›DÇÛ’¡…¯OHQ‹ 3Ì§ú<£•C*"5©ÌŒ˜EÖz2r'ÂÂÓb<»g 8(—‘0‡¹¼ý¨Ä1å‹Ô¶.¢”ƒ$OHÇü‹]]ynI×<‚êqú—	õ¸·Ç´UÖÞ~Ua=U”uªÏ kÒ{¾ñÐ¢Ž#b¸.¨`pÔñGWyµa’K$Vó[&Íá‰ÉÃQŠ¢xª>Ï^¬C…ÊS°–)¿LpPãZeh™Ž¬ZÏÍIýˆGNám.²“Ù!Då|Vr739Îµlªëùp>j,öA3 ×µ;ºC2ýÑÌ4vIéÍº%PP€’žTQ§ÿJ™ÌX¶À/IEµ@+…† Áæm‹w@
X‘k1þz-TÉ¦+ŸÀ€Îˆ/<zÅdóoá®WžS/OÍ^Ñƒ,³!t¯‰6ûZ»f¥‡»ÓØ–¾ùŠË}¼âÛ&)¦¤öÍaË>ÑŒ±Îcâû-€•…=‹®è3¤&ä¤É¡¼—"{M˜‡ÙÐ`%ñš•í÷%`SÂË·Çüôv,OTs§åä"ÔBæY±‰Ó&Ï1¨<ýsE*j$C˜ÙhAÞ#ü\…SÑ^õ[˜‹Îaƒ 7£F\0™RÍµZ¨]Í]É,o~ôVÉbÞcfhçïu!ë™Ý<î(JŠÒ¯Å†òÈ$ÏÀNqoYF²bB2vVÊKŠ»YzRuEqbÀDÀ“Œb¹\CUéó‹³ÙŠGì=ÏÃ›-ê o_)!IKýkü°¬úE’uVN<RëéEúPé£•;Lx,|YÁïž€ó¨´}gŠï_Qß§#¼êÑ1¾Ð0À³íxýŒÆ1¾1ˆmq€Ãû_ xq¾wƒ>¾}M]|ëxžË?e‘Ç¦mß¯¼J)0¶•¡)ð/‹®EÀh¨QréÏeýo!fh4¥O§&Uá_f­ìç|rå$¸¤p÷e.R‘™Ø%Çƒë‡áFkÎÃA‹îì5›t§UÙ,/ï8¥L©GÎ’p‚	ÅèzhÀI24ÌŒ¾6î¼ÚÌÅú‰w²šNc»a7ú}¶WÔëËÉB\þäùbù]–~ºÞÌÒÊ3ô³²<K@%oNô^³Uo´X«Ö·is×¦@4YFõ—J¼½)±óÀFI4Ï$Ñ3Etˆ¤Už¹ã_ôƒ1õ¦œš]}1µ½zƒí8{ÎöÞ«mïl¯@g2±éMµ·)Ý®ï;Î6­m×š+ Ús½KlÇ|T»:ó’8¸…†í6÷ƒþÀ®í5;wXk‚^ŒÜøÌéÆJR§m§9Ø´œ~‹vW@õIÈ˜ÿQáØ’P´¦C`ËV0~“(vùáü; þáî Yk9ƒm»±·Wg»«x ~ú½^æôº®3,pz¤ÿJIÛ;ÚNsÐX«;5¶³Bû>¼As0h6¶˜=pš{ƒÝ½ÝåxÞÊvn¤½ô¦¨?±ƒ|2YPÒ; Úa»µúÀ4èîž³WÛ[A8·ó€7¢úÂé;¨ %°åîÓ^é‚	XxemlÇÙí·êÍ:Û«œÚr~ÜM:RÀŸ%¾þak»ÆZÍ½mûán­ÙX!…úøêzá»èAo º’yÿšçç%Ñ‹„:4-&øC+SQrðí•„h½ˆgxWÛEN…ñvþB¦Ü}åŽé¦o˜þ ƒ<B²*E\Xc:Ñ.¢Ç“ßXÖÜK»%rzVWj¤ÊN¢¢Æ8Y"HËQfn]ceâAï‘·l•+¸y”ö19å…ÃUÓ%z£YŸ“Rž/ Ý+´:uÊ€'xU•ß+‚mñÓ<é)Š¢y‹Ø­7(Ò>iÍÐ.'0‰•çóÃ¶¨«ï¥ ü™Žuó´nÉè»kgMç´³²•E×0ß/LÏ6´ä23#x[7½«w•fÁuß–#mèÃÂ4S¸s((„D´=Ï ­¸gwR¤¡/„<‘_›ƒ¾ùX!.œQw%|WÚ§YÐ&œ»]£u>º©;zL^¾z¤šçØh_ÏûÝ!™-ël8)ÔÇ½Ô¼šmôk¨œ³ñ#":
BþÛ¡€R1˜—|™Wò°æÀ± ½µG3œQ#gÑÊ¡v£ p¾GUC7íÛy™Œå1~YŸ¡W’ß*˜AB¾ lKJ#ü@œL,¢[Ž¯,¤´à[woVYMvÅ„×Šò¢9“E
VÀWñàQi>¨L“$nàëÚÜ,)™ïó·ìÐ»äWÒßg_ÿä§²6ÿWçÍ—þôù™ù_5Î^ÿþ©öÇùiùo‚g¯ÿ$3ßÏOÎÈ¯?‚¿¿«jÇóÍIùúÙë_ªóŽë/ZøcáŸí©ÓyæŒüù¼ìUÝËÖ;ûúÓß}¶ö÷?Y[‹=#ˆ_¿…¯þ¶·­·Æâÿÿ5øÿ´j­Önmw­Vol·v~üÿ?¾‹×Ë÷ev¿Qû_öžv¹#¹³“\,¤’\±Rùð¯ñ’1I‹XbñH´E‘ …’Hâ@ÈŽ‹äQ‹Å€ÜØ…w"iRy„«Êä5òù‘çÈäoº{f?± H‰¤/1÷‡îÎôôôt÷ôôÌtWúZM¯¨ù¯UÊ˜Ad9ðô.Õ×»ÃîïàåI‹/«U97rå^YÕŠ%^­†Õ"÷ž²Ñ€ÿ<Mù	J`& Ýéí‰œ!t·ì™Ô~©™C‚6û½\/¯Uój¡XéwçµiZ²½éÊt%´1û
[Z±ì
[€]jÅv¨'«ˆU¼½Pêš–[S.•zþ;7L§px¨ô¸ž/Vªª¦w5ð=>ºÒíñB·[-©½^µX›Ó“!T™Ó•o¶ßÞn´íå¶Ýèl6_Ü¸K0³;&Ç¨¶Kn ¿ü$ÐÉRYt2Ÿõ²Ò+–«<_VnÙ¨E;™ìÐK÷ÜôŒ³y}’1°¨[ßPb¼uç~(½ðìÀÐE&£d€Û{…òüˆ¹gàÇõìc`-¬Æ29Rb}€Â€yà³=öFcL»¢}
…4&(•ŠE½Ôíªý\¥Z4¢ô1]/tkyµØÓ&ð—7ôæ6Ûiïï²Æw½B(˜>ƒùâ‰M Mâ8ÃélÑÊòµÃ£Ìê#ëÈ¢–{Š›Õ“#ôË­cSïä)¬ÎŽæÅ9RÖ Ù£Òfoðýõ·{ú$AhËæŽ£ÔsDrbÅi–LHW„ä	f½!G¾Øü®Á» [	~”]Wéò×õØÒ²ÆÀK×b¬jz/{5^ÍU®ÖrzžÇ/þåÆŒõ}»Ù‘)vÊf:f¶lËCO‚!f–ì]¿§·ÙoÀ˜±Ðß{†ËÿYÍø0Y8XS¥––+Qo½%%«øR~÷oÁM•ñ?Èrâ^ÜT)ñZ.´é(cŽ}Ã–-ÛâË ËË$}}Û!‡	õsOà¿§W¯‚XZ¸“?NoùÐ<~Œt<²@¬%8`Ö×ŽŽÜ•ÃßáÇ_­.­¯-/iÅ .A
Õ@¿UÏ™ú)@:/?ŽòÂãeÉX‹Ë“|#j‡ªåÍ6øKï#
'88Áæ	¾ 'nCÙH[ü†“\`Êå ÷.É‘#?à2ë&Ô  üÛÐÌ=³ÏÛªØªLæ¨#¥³¬\Q‡‘;&âÕ±¾L%_7%oàŸOä§‘?ˆA ^¾Ä¨¤?…iÝ=²’]ÜÛÖ¸óÎ48ëp}øæI8r:ˆ©­PëŠ?¯Ò»š4
å˜Fªêý\µ¤uUøŸ—qÂ¯ÕÊ%½gôÔ’¡å»Q5]V*)4I‰¦«(ëw”~Îz#õ”:H‰ÁT¬År‰Š˜=K¦L’zÓ^ÉŸ½í@Ãáä]IéQˆmr¿áÄ!ïÔþÀöö;Í­FböˆD¼¡I‰|Cc¥TM3V¦,½T«E^P«µš^ŒŽ_bd‚ôxw|:Òð|<DˆsÚ›ÒrE¡{€£TXó©£”ÀöÆóÞÎïdQù&tªIE³ŸÎ~k¡mµz}ÓEZ‹ù˜ïgý××»Žid{ü]Vˆ”»~ëmà"¿R)ÍZÿã#Öÿe,W†õQËU~ÅJ·ŽIÊó_ÿ§Œ¿SkÏ>·6ƒmì¨îÙGµAã_š9þù\Nä­”òôá›båÁÿsÏâë]ÓZïêîY&³ˆ×ˆ_°`Ž1¼¥SjdgmyGÒ[–ˆ¦A©Ø€k"ÃÁÆ[YÍ¼ÏdZÚÆÒJXˆ\–ýq5cöÙ!S–Þ·´‰Â¾Ø`ŠÂŽŸPb§X¤Æ™Í”—ÐÅË…f§ÛQû2ÿ5[†]Ç¥T“-ž9Ó7¡ñ|¼q=Úz~fëmì¤ßüušu†Œ ²lÛ wÚQªQÎVCÕžs PL!šµB¤eé8âóñÕ®Â×D„#ø
 ;xŸú,D>Òuq'œpYÁ+øÿŒ!Š£IFwH…‹øùFW	UËõe‚(&2Ò#B^Y<ŸR<^2úÑ¥ ¬Ð€Åôl¢÷\ÀývlŠäZˆ{,R–É´
JkÀu—3—£‘/3ª‰åûš)¹2ÚX!Þd_2"6W$Õ9kJš+Ø˜²š‘€.1	&›pøìx¢<$h+ÌÀ&—¨L°Ë–l`•¤é	c]X‹¼}nÇ%[

Ò<™®@¨A9~azò=wu#ƒ33?·zx~®'eþGN2ý±¿|æÌÿ9-ŸÏÿZ¹T(>Ìÿ÷ñDçyÜNYZaFþë™"Üè0´Nö_··‡9ÐclUÁ¨£óüZ?!ý‹–âƒ.ù?õ¤È¿ØÑjq.Â€âžÑÇ)‚Ë>—/çäÿ>žùÿe?©ó¿îx·i Ì“ÿ‚–KÎÿ•\áAþïã¹}ùÏ,n7Û $³h†SwãÂ.›9¼o^`5 8Q p€ xó u>þI‘ÿª·ÔÆù×*…)û?Åäÿá(ÙÆ>öˆnÂ“{Fœ¥½ÏWºc{ "™Ydß:zW8iÆŽƒ @Þ9ŸÎ|¨"è¼hœlµ›­ÎÆÌj+«å”7Ò³Ó–ŽÁå¥÷‘Â“e@É÷•½xu²³ù¼ÝÜ:ù®Ñ>hîïMb^³Ü'dñéÕÈŸ8ö ³Ùîœtš»ý×+€ÇÊm\"l(û[zÇãñÅ$lBúìbpËzl¹Ü[ÃCã!ÒçlÐ§)™YÝ•Ÿ1 Òl˜”vËRÇ?-t§ñuj6Ö±bi¸k%¶ârŒ~ï®Nu!NT­$ú¡séË¿;ÌekÇ—è¦  ø;<dK©oü[r8;>fÁð‘ol&ªu¶g{˜{y<ìrGa_™B^5¦a]¤ÉœŽ&	+ ÉÌqRAt×•$[@%.
°é3åš3âû?·fÞÜÿS)TÖ÷ò<¬ÿ~ÙÏLÿ¿•ÓrlŒµü1j`žüçË•¤ÿ§R|8ÿ/ÏíË?m«Ñ¸·ßiÔY*;Q0k+<CÇwt¨î]NÕJjŽ1¹‡Q³Ò}‘ìAÉÜÖ“"ÿ	‹ããÛ¸ùùŸJL‚‡ó?÷ðÌZ#hÃóô¿ÿ¨þ×Æÿ~žkÿGì
ÏÿR)yþ+_*?øïåIœÿjà:O¹›Žë1ŽŽ×ØÈ1eº4ÃuX«\Ãf9:{¹‡g]tÇÀ@@tô<³ÙÞz±ñfL¦Cvøæj/QðCý`À?8{tˆ™>ÄDGÙ†æé™‡~$ƒKÿ„´½¿õ²Ñ>Ùi¾jl‹oÿÞÜº8<åßÅS/‡ƒŒèåþËâŸY¶O>ê" ŒòóGh¶\[þ?bWxŽüWŠÅ¤þ/â–ÐƒüßÃ•ÿTñ$ý5Æã¢ 0„{KñÐ—:Sgð;Ìž±3ÛõŽá—u¬LÕ—Iªêþ‹,ˆü‘•l‡e³X³~äy+û2ÁÑ*…Öò£¦ãwÊÝH9i.ý°È û–¼²3kŽxK€·lsˆŽÅz¬žm-{L|Á«\6Ã»Ê(ÄŸî@ãBÇ[
³I«"\…“L¦¥;.?ÙtNÇèxwmÏÏpytÈ–YöÔc9ôžöìÌ£Gâ¼ †Ç=ztáƒÑ*þ|ô¢ñªÕÜÛÙßÀôæÉYió{–=[
âž™}OTß?@·´¦øU£ÅB!K4¸·ßÜmí·;‰é<á£G2,„^xº+…Ø$;Í–žE|ë²# .1ý/]øˆ¸Õ#N#ÿèì;¾lá¤ßÚ‡^€
ßzÕŒù÷ß6–VÄ™QºX%i!¼ÈèŽ˜_Š2þ\Š®cè {”òA¤ÂúšÖÂˆÎf::,ÿup¼7B¢ô²Ù¬ú÷L?Ë²;*[~ù–òOµÊªt`ODh="ÃÒ7 )?2-6 k\„îŒ$äòáƒT]”©¸à«!ßÄä²Æ¹	=çLlCD[yíú9Eü€‰tZZIídÐGÁì0@òžL¿u†©~b@å¦3^ýóÈQFåpJ²ìšH<q`(ôô)kìï°¯Ù6w@çI¨q(žFFp’—Š˜Ük•‹¬¸“4õ¹Âô:æÛc¾r9ùMvëhjNÍùu ¼¦­Š7­uËü‰-`…}çÔoCÔ	PU’1Y/h{:•2âxénFI…[=¤K(€¸’R¡¬ /ÆÝëkóS¿Øu“*òR{j0J¤ŒéSðxx%NCŸAä×iBÉ¦°ÚtDPÿ«ÊÅÜ@—Fãà´îlªç0e'×ê`”½$Î˜êÚÐáM:ñy÷ ¥ÌÀ5¥ß3p½²ëw0ê$ú7ÇÞ™¹ñøø†>øL"Ã“”éaš"ÇØÁáWN‘Q__ÝSÚ¤^É•"olz0¯Äk6¦%Gäõ¬â…Y¸Í¤v”ùS¨<S™-1Òt1‰©¡ïI-xåðI<Áj Ý
öQ»ùÝf§qò²ñCÊ’Ìp.Gž-cÊ¬#u÷£l¾žlfíwwÌ²gSã×1d)xëšVÔõnŽWÊÝ~Î¨T¹j¿Zã}£Ø­µb¾ÀZ©\íé9£PÌºV­èµ®VÑõš^,–*'îÛÌV£Ý¹¬1—é¬BYü¨Žø0´³|ûMÞ&š¶³¶6ÛÛû¯;­×uo8ZìÙg4]©h‡³k¤tjA¹Ÿb–Q-ã¦fG³çR–³ 4ËØ	$0ÎúoébTÈ*øÎ‰–vØ–Páòï,m@,…Xß€0f†E=€%F2KPE.b%l©+€õ8Þ{Nç[7W˜{@ší²¿3Ç‘Íƒƒ½
­(%zÈßÕ‰›ª1¼·&–iègE‹ËÅS<¤;–…*p†³±MØt7ÃFpÚõ‘"ÿÜëó»~®ïÿñ5ØÍÛ¸¹ÿ>kþÿûxn>þ±L½Ô‡ƒymà —‹³ãÿUŠÉû¥bA{ðÿÝÇ³Zstéc¼ù|þrF*ÛXß¹¬Í‰/zjfÝì­íÊÊÄÍÙ0ån]&õ¦”Ø‹èÉÞÞÐ”}a¦ƒ­äÂô†Bß´LOúbË/¥Ÿ¢ÛÀOkÙ=îÞ2J|ê0Ý.p„'¸ØY†¶x=ÒcÛöP7­:‹˜ôþ¶ÛFˆÊÌ¶4Š˜]¼%,`œ 1´¤¶$B¾€$tåž»l•º´Æ²ì˜GòÎí3²ßßks1.î„…}LîŠOµ;eÞS-Æ¹ÉUÏ]³ïÁm¡ýÙä8uyI‚[zw â!ð‹ÑÀ4LD$ÊBhÖRŽŒO&á‰yzì_©Œí¢éK‹J‘›ðsSÈŒ’~ñ5!‚„CÝÆc[ºfÁ—€†u6F´ß]bÛ.9·q«æÜ†Eô¤¼-&$Ž±L¦i:¼·Ê:”×ÒÅ?¨SXd¹ºåÊ€8èj˜þCÛ¼ÙÆ9†½¨æÉî¡o7  6cö(‘o 0þ`Ý­=èßóK$¸>xkbtÌ8àzŒbW>Êû÷ªßùÉD…¿'O&Ê•@dpŠ.îkCû¦aŒ¡ƒt„ŽryBŸÐùb$!Ùææ&ÁÌÅæ;>¸TïŒµ#Ú69ú}Û†w°Z¤A\2ÞÌð‰®DGÊæ+Xº-ýÁuƒ¦²x¤Çv~»½Gçðõ.”IE©«;3ÞÿtwÊÅ—À»Ó/`ÚÙç.M´"{lTh(CÛáR•Ð®•îøç0{2K˜gêƒÁ¥HŒ§2 NKÉÀ¶ßÂ¿æ[.¼ ÿØSD­*ž-{lyYÍg»ì1L~—¡\"–â®bH3![¡J«kô‘î«Rè«Ç/ØÊþ½*ÁÉn¢?vÅª&ÏbSŽDeÅãU5&‚{6Hv )–ŒP†HÜŽ½1”Š1» E +ü~9ëÚÞ™„'Uºeƒ­ë§§ÃÑã²w¤—»!Ñq¬@£Ð¦§0°]ÜZ“ðyŒPiRÎ‚;âœNLÇ11lu¹sGÒd¯³Rð"Ðn-ºÌ9™ÀÏ&Ód%$›Ü8½v)¸Ð]Á—4èÄ8çV¦~sÙ	ÌÆz¯Gv‚ŒG~©;Âˆº› 9‹èXÿ§Â«ªzsÖ˜sÖÿ¹Rejý_*?Ä»—'ó?ŸfN2ÇŸ}úù¯?û¯ÿïÿü3å¯Ÿ_=ã…nÎ(óµjßÐ­XÓûÝ~Ñ¨Öjå~·–/æ+:/j¼X.ÖºµBÑÐ‹µR­¦u+ÕR¾[-•þíÓÌ>Í$/l.üCæ/6G8ç“uºYø,ó§hÚ/üêó¥Lf£‚jþváo2¾7|ÿù|²ð‡Oâ@þõ“Ï>	á(Jæ×$rîÂß/üÕg²ñÿþtYü‚2þ=¦fuÜ…¿[øK(ô(x-ÓæxÇ!RF¾ðË|%ÿ¿î?÷È‹çæòfŸ{vwlz ùÞuÚ˜'ÿE­˜<ÿW®<øÿîåÞÜSŽÙÝ,îÐFœôín¨)¾ÞLüîÖÎ·'­ÍÎ‹¥Ö÷ÛQÎ»@pYyê.Ø•‘þ¦o¡X²¬‰û|`oñÜœ?«œŠïj?\Qnëù ¶ÄE#ñ²sNUÌÿÝÜf	}ôÿ~¯'íùù_Éµ\ÿô\-ÿZ®\˜:ÿûÿçžž»ñÿ£AºxËµÏ˜¼@(ÿÊ²m³ßçtþ3æéòýº´ƒÅ·#„žAa™æ7Øö%Pº‹éZa½âÑ}Û?EèÏ¶Øìm÷Kö÷Œtl¤èKßªg¾ß>|ÏÓ§uö•ü²-VUn¬@ì”I¼.#:~ni_Cc%QeÚš™9§Å UéÈM(õz
õ”vƒb0…4‘¯L@ô®˜ú@¸êq<ïD=ÁÂ¡ ¡óGwôLäŒçº¤Ç}
­‹¹€©’Ò€+z'rd>â*¾VOÙ÷’Ë¾}Ó-¶{Ð‚¥4ºuÈÇCE¤ÂXÓÃ¼ãAYæ,ì:v$<“¤¿7ôêŽ=_óä<ôV‘oÅ†œˆ'L°F–}™"‹LòO]Ä0: ’æÓ[”äö!O^c³®zJNý0·Þ™Žmáï Nlÿ‘‹@³TeIA¨HÅˆ‹O¹¾¹€€BQðç¶éø¾mRM—.Ô£wÆü“î–ð@ûÄx' &@áðè©7;À<rð-q¬-Š%R°û}FÙ<Lï2ð^ú–[ pýÕrLS*ê¬mÄÝÆîóF;ê©öG9œ¨_>x é˜nfá¯qÜðÚ¤GX×§;²Œ3ÛÁmÇ„†]Œ~Š^ñ}Ót¤Ög?PQ™!Ñ²c»¶ü”ÂsDW-Æ–Ôÿ >Ð£+}Ó´{‚C‹a¯°|“A¸\™0Z™ø/#K ¡Q8ø…ƒ&vê,ýpbÂiá}$†G~ïnÆilušû{á1€¹sÜg¢H¤‹¸¥KÉgž£[®H#¤'`q‚‘¦•G2> ÏvhpÝÍl#,¥@‘S¿œ(äk†9v„×Gw¢8J©îï¾Ò.ƒ¿‡òN7b3jŠ Åµ¶B>}å­Þ«·³lB´€EDÛ›½žÃ]—G$!ËRÎ¢Ó!sÝçº¼/ï†|õ!zyIéÀkÄó\7ñŠkßöwm(™ëb]‚CP y7ýÀü‰£EÞÜÄæËP¦D $ƒX@¬Õà#6£èlWÔúÌ‡ú…9Ó °”†/ßÅ°'å¦_Hhþ&D.ÚÚfè<†¹›}~é‘­ü÷Óív±Þp¶ÏÅ~KT¢®çŽ© [½Å15Tq²	hY6\«²ÝçQìZd}áÆv½QðáÖñc›þk0ø<*ëÁÄ)Ô¸ßj"´/[¤(`Tš¼Ú¢ZH ³!AJZž½”y‰rR´üÜ±ßâô ÓYjè:•a]ñœf /"¬ò°¸$BÏ¼v9k¶êä°²l/n›øm%Ô´–¯àí*U«×rÿËÞ•t)Š­Û7æWÔèM\«¤oµÖ=4"("LÞDTTTT”_ÿl"*­Šì¸g2#Cáè>ûë9üS|žœó"^ßbvÍ_º¿­+ÜIsòbPîç×=ñ
ú;‹éó÷ž_Cœ/šáe˜áo|©”99~µ|¶U³ŸmœÕlŸ[ˆüï3‹ð½ûókýÆ¯Êÿó“ù¿ß”þýùßämþÌÿ~üìú?š¯ñÝëO 8ç¿U‚_¿þ&å¬?A`4\ÿ*ðgûÏözÙ:éÍ×é;½ÆgñŸÛZõ?ŠQøŸÃhûŸ?zïô~¾Àëúï²ì_ƒÙo=þ_Š
¾ÿ÷
Öº/â)ªXÿàê:ÿòÿû£	ü_Èþ+þ§ò¨Œÿÿ¡ƒAÝ×ÿÑùòýüO=êò¨›ÿ÷KhÔ	ÈÿÿkçŒyäòhÿß_øÏh÷;Þà†£*þÿ—úŒBñ§üóÿß·âQ^’UãkC=µ£
À–î%¥ºª
ý… €XN@¡ò QM¾›Ávôz86óÅ‘å³Ÿ$ÛYºèLS×Í¼@ÓG¦)KEwä”’­_^`Ž$ðºfâ<pýc´¢6ž-¹:oÞãOºáàƒ*ùgÄs©E06a)ù:ÝŸ<ÓÍè®õ!µŒåÎ>’OËÞÊ8†¶4Õyôv8éîD>•ˆ‡K‡ç'ƒ¸S '£¸¾ðNúÂ¤ô…\ŽïÇÌÛ1äzPïä'¡]>1F<ðl°Ùº¥ÒýòT©Øˆž{Úø+î®–3ÝòŠ¸=¦ RÙžK&Öº;WÆ&Â£n±…r²(ò>ïËØ&LùË½ˆN½Õˆô\¬eçàáÜÑ;i!ž¢e¾Z.P˜žúò³ÌH4 ›ž³K7vÔn‰Ç”ÛÒäPñ6a‚*‰LÄpëÎU%ŸDÖP;br/qiÔÊIW‹¬D[ÐP–{n;%rÃ8Ï{	½!KÒêÛ‘ërV bry«: ¦ÒæÁe}7y¹Ó“®iÞ–Nr˜N‡/tþòYØñ‰Ôá/ï,€Ž\oœbé<˜²Òå Ð¯'_ž¬fªPûx ”v’bC>Žx1d±r¿ëÆ|¹JT–EŒqŸösƒt´\ÙåÕ¶òP'9þò§ ]2UaN¡³åD}vÆ±p<‰9;Q÷Aû8BV§ÞÉŸ®%÷R_s^µÆ[s½ S±I’.÷­	ð,Ù(cª¶DÚž®7³5ÿú¹}#$C|ü–Ôýþ94Cÿþ_ê¿*ÐýPûÕ…Fè?œxÔ°þ³¼¥ÿ†âUÿµþÖÒqlcÇ/JŒ6]ZÂú,þæúOñ~µþK‹Nq;A“NÏuß«FD®"Q:ùh¨oH=?ù_4"ò*Ç³i9 kÔ’™î8ñx¯åc±Ÿ3¾k;Ñâ¼<vÔŒs<„<ÇõqÌ·:wUšì8é[ÅrÂÆ;Ï6EL)“6¦z-5¢¼Ò{“yÈE$ª:ðd¾sŒ ‹ÛÉöýd§ …Ä·K°¹éD“”ÔÄL?Ó– 8Î‘Œc9îãù’TúX”1•.ˆ™¹-
!ùûz¥Ë'U´.ÒjÒÊ‘äúr:c+’J¨¢ŸóŽXtÖž›pó3Eì»,F¥‚
Æ=Å¥¡¤x,É}m4§ßéï¢2A§b0M§Saudé•ô»Âfè?èÿ«MÐ/þ¿4>×}7>šÿ!hìAÿÁùÕà3ý÷2CãMò^õŸ¬€D:¯Ëüùîq¹üþ·÷å²m+¼ŒÁUšf2ˆ:µö}»è´ÖÚÙ·zÓXPƒIiÉ—gv°ÁiiÌ,` Øqº†K£l“ý–ïv3u2_Ds:ž¡ˆqØjŸ°SGÝ¶ïÀ‡;K.gÞæ$ƒí`«‹ƒ>oÚqšz·ëÅ`&QÆ§Ýùá¢ê¾áC#ö˜ÿQêÞÿ¯Œê¾MØÿQ˜ÿQÁÿÐþ«MàÿOìê¾ÿ!ÿ×ÎÿýÈÿ4äÿ*Ð,þc‚iÝ7ë7Dâ¿$NCÿ_Mx+þ+_óÿ"á5þkãÐ_ŒÖyÒæås6fæ™”.Í¯#pETJ=Dé=¦;Ó…ÑH?I%°îAÔÄRcÊËUHt+:àÜ‹lqtylÎËH´ê<|Yz8{’m0¾ŸÙ’ÌýR:øãÙ,ó¹?¤!Žž÷st[ÂÒ[==±Pf‘¡ÛQa,T\·U´o«¸{=¶¸C_!î‚¯±ìe#¯±ìÏBÙŸÂÔEáš®µ\
<Ró>òoÞW€ª€—¬vâMLNOC[e½#cŒçžæ.¨=-Î×²»¼²î¥îˆYZÎÔ4 u‚Ép>§tÆgüM!²ÆQs}2°hŸ”ÎrRhÛæ{: eäÃ¯!ÚÂ¼®­’ˆ@3¥_íüàÀð*Ï!;«—Új»YãHúý*th}Žw)…‚ÃcJ_tÉTS sÍ¤AJ¶¡íÅ$”åríÙÚo1¢JÅÃµë#î(LÚ‰š)ÎVF÷<É:™´	$µÐ9æ0DÆ#]èü,sœŽ~ßœ¾ïA#ôŽ~­ÿ(†‚ú¯
4Aÿ×‡  @ûÿcë¿Fð?õÄÿó¿+AÃø: *´ÿ?6ÿCûÚÿÐþ‡ö½ñÿ'ù_°ÿg%h‚þ‹hü×hÿlý×þ§úBþ¯Mâÿ(xŒ-ÿwFì
{RÿMAû¿
¼eÿ›·þ?«¿ë¿ÅnØŸ±¬ÓÚ/»œSùÂ)øÇúï²–úïHç³×úoûZúüLí÷õ¢+ú×~_K¿‘«ý.
9¹÷B¤ÓÕ}¿–}#©‰c´Ç‹lšæ-µÔºg~5émgí^;—|j_Ø[o“kX¹7fª#n–ù2ÞƒN¿kº–ÒJCdVv:Æqˆm‹c,[}9‘šo×}¿–}#ßS÷-ûå–É¥DÁ÷ÒÁÛ`»Bü.UÌ2’>šê8;÷¼u:m¶ä?Ö}çÝ¢½t{Þ¤Dß#'Ž]RekÞsè]+ÙB>‰D¯Ôz‡DPåñ2r(:8ºCgoyÍ‚ã&¤íþiŸî4uÛbNuv”Û¿›Ó úÆÿkCôß~™C@M€öÿÇÖàÿ¯ãÿÛÐPaÿÃþoµöƒýß`ÿ7Øÿ­Þøÿ“úOê¿*Ðý—Æç|ŸíbhýWhÿlý×þ'ð'ó?¡ý_	ÅÿFAˆÆNÑˆa	”²\<È8'b£hv A¢Q€±LÀ…\@’óù{}„[4ÿaÿÏúð+û¢¨Zôz¼–ÍÛÜ<iÄïƒ:ÄÆ±!»ËåqÙã¨´4s^úZ»£›Žamt'-;À´Ê¹–Y+Œ„¥ÎÙ´¨3ÕYÆ”3Rpyž3wídÙÁîã1D -:‡sOTl4^Å¼>ËtöÿüV4aÿÇ¨'ñ_¸ÿW‚
ø¶øl0ªXÿ°ÿHÚ• üO?Ìÿ‚ý?+BEü[|4ÿ!ÿ×Íÿ8ŽCý_ªçØâ£I¨Šÿ¿·ÿ
ý• öÿ€ý?`ÿÿêžŸBôßÅÚ‡óŸjBEúÖ÷4ÐþÿØú¯	üc$äÿšP1ÿÃâž†¡	öÿ“þ$ûTØÿöÿ€ý?`ÿÿ‡úïõlñÑP@ûÿcë¿&ð?Œÿ×‡êù¶øhaÿ?öÿ Øÿ£Àþ°ÿìÿûÔjÿ“Oú¿ÁþŸ• ‚ý?
 ÍßXT±þ?bÿÓ´ÿ«@ø§ìØÿ©"TÃÿ„4„aˆ’,ÊL‚	†Çd„\4Mr1ƒ²4A8AqŒ	Ÿ°\L21ÐA{¼šÀÿOú4´ÿ+Á¯ìÿá÷ÃCZª‡òV3ßÆjâ£N¢Q3c;"KÚÐÉÌ¤â—þCKÇ›Dœ‡Ã’\èÙZ•}ô°UØc«°õŠàû›ùªØû(.ÍÌþÊ=h8ä’÷¥)mÝqp®çîŽô;ö®«ìÿñ­hÄþ>Ä©«ÿîÿïjöèðo*ªÚÿ¿7ÿ&àþ_`þÌÿƒù0ÿ¯ÞþoOü?pþk%¨`ÿ¿%|À@3QÅúÿ€ÿŸºú¡ÿÿýÑþÇïŸ/ùÆ+AeüO¸àBÓeÑ)ÃN°`J‘:	§Å“ â‹bšEÙ)C„ÉÆ!:‰1"x4ÿŸõÿ¾ÎÿƒöÿûãWúÿ‹ik<_ïçëlé´Êiìé¶­èþS“ö¡O¼<œFG)xíÿwÚz{KO-)ÌWÌTR¼#µvˆïí—>bXçæ²Î|yÓÀÂöDPz§(´Ý°ë-vÉÈÚÍ–Š0"P.>ŽƒùZ˜mÚKúÿ¿Øÿ±'ó?àþ_	*ÛÿaÚ#QÕþÿÝó?aý%€ùÿ0ÿæÿÃüèÿ‡úïöÿë)°ì¿¡¨býÀÿ«ÿ„þÿ÷GøGŸØÿ$äÿ*Pÿ_ÿEì¸-ÔÈÿÿëçÿ'ñ_ØÿµÔÍÿû%4êäÈÿµó?ö¤ÿìÿX	šÀÿ÷þ3ÚýŽ7¸á¨Šÿÿ5þÇ0ñ?‡ñ¿*ðVüÏ/$ô§ù_ƒ„ÜËâÃjÌôN"&Í¥“÷0ÿk²¨eþW	&¯ó¿:k+G"Ü˜ýÌ0ävð'f€!ŸÇ3ŸÎ ;én$–Ñ<T"×!`oÎ æqš‘–£v«·Ï­ÌÖxŠ¦þnŠZ6¯uµ×Y/†CÑ’…2Â[‰azŒ6Ò¤ÅPF7Åp*8˜¢¹[pÆ~½Z$~T ‰o>‰ï¹ÉË%\ë|n×+\g€™N‡/tžO’ŸHÞŒD,¾a`X€ÒN’AlÈÇ/†,VîwÝ˜/WH¢²¬1îÃ~nŽ–ëBr{²dš3o	5¿ôÇjñ|©qáÇ÷'E@—LA•Fªí›N›ºeÄ·<OSøùÜ›Šjodôt»‘›|Ñï9¿ˆ¹v<ÌúöY h°Ü¯2]!ÝýVwÙ"9ñÖvÏ©ÝÕ¶SðW£5Cÿ=©ÿ†ý_+Aô_@íW¡ÿžåaPÿU˜ÿó¿`þÌÿ‚þ?¨ÿjöÿ¥ñ¹î»ññÐ„øÏÓú?Øÿ§üÊú¿ƒaJöA“ZÇµ›0É9øÖ”ŽvÒÞNŠÖß_DÔ0Î³ÃKýŸ)õº/„dÐž3qÎé.·1ºr@”í2-†óHN>‰¦	j%9a3Ñ[çeÁ+ÓCËº«‚.òhàš@5²m‡>ëÿ¾ØÿaþGm¨{ÿ¿ªû|d4aÿGaþGmhÿCû¯64ÿóy²†³AëäÈÿµó?E?ò?ìÿ]	šÅÿÏO‚MBÞMˆÿ’8ý5á­ø¯l?Åíno¦4®iær> Ìþûwò_Ýÿû×}	ë¾;:ëÂ?‡u‘·ú{Š³aZ’â'5\ÆîÔ–z²÷æÖZ©C¨k£=¢K«þ†+VŒÖ*ÈžÊ«I	%'²ë­âÒS²ïñ»pƒFCymÑ†¡Kù-¬‹|×Š{öÝ5l[˜‚@¡ÝCº^05_´ñF^ûxkïáåZ¦:9Ç•G4‚cíã¢›Òø:³xíÍRÝcv¼AðF[VQ‚9èÛ'‚.g®Mòüˆ½¬˜às£–Z «|¢rÂÙ§¸l¤V†g6;-¯24Bÿáè×úö«MÐÁd5‡€z íÿ­ÿÁÿÔÿ/Ìÿ®ãpýñ?ÐP ýÿ±ùÿMûÿ:ÿ+>Õÿ‡þzd´Î“6/Ÿ³13Ï¤ti>ÔÿEe-õ"^ëÿ$Ü˜!?Sûw=†üLíßÕ•ükí_Q¸¦kí—Ï=¼¼Yû'XíÄ›˜œž†¶>ÊþŸ½+kRTÝ–ïü#®ÌÃÃ¸Ì‚‚¢ êË	@&q@QQýÕª²»OéÞÝ»NpºV>Xƒ%V~¹¦\½#cNÒi×]P{ZJwhëBgÝËÜ1³:ÑÔëò]Å›Ò”2˜3ËK‰5GŒVóÁž‘òYËîÂ¶…žÁ“*r‹õ¥×Xÿvo;±ôã|Âj7óŒ 	²ö²²»Úæ«Qh^¿¿CE…6R\§:¤ç§òbÞQ³D²èZ4"ÊñÖ·§!ÉzŽr¹v²žµI£ÂÑÚuÊ1wçíX‹GT—Þ¬Lý<ß(9÷d­48æ0B&c£3ðÐô,’sœ›Î‡øÿ†Fè?ìIÿøV‚&è¿Àƒà¿.@üÿµõ_#øŸzðÿþ¯MâØR=šÿ?ÙÿMÝúÿ!þÿ|ÀþoØÿû¿aÿ7ÔÿAÿÕ¥ÿ^VÃA
 @üÿµõ_#øêÿµ¡aü[B+F#âð«àÿþoàÿþoõÖÿŸÌâ ÿª@ô_ž‹ýfBô_= þÿÚú¯	üOàOöBü_	ÅÿóÈÇ˜ ¢°y€ÒØœb)Ÿd)”â8?DCÒg}&Ø ¸²„G3NøJt@á£!ú¯â³>Â,šÀÿàÿY~§ÿgqéÍº‹S*lm¥mÒH±)ØãîÂòÏµˆcÙY(Ædûªx÷ÿdÙùh}$‡ÉÑ—“Ã˜šqr×9‹ùs™&½Ù.›œÖ1Xo’ÕšýbÇHqË©$9½:8‡›¹Ÿ·c*V÷‡õð¤yóøþ*þÓÿÿÍnîÞSÀ»ßñÏõÊ ÿ*Á§Üÿw¾? ÿ1
î%h‚þÇ¨'ý ÿ+Á§ÿÿßþk ¯£±¨âþ€ÿi† þ¯àÿßšPÿ¿ú:¼Ó…€úüü_?ÿ?©ÿ‚þ¯µñÿmñWÝ< øø¿vþÇ±'ùø¿
ÔÊÿo‹aùw}¨ŠÿÿÖÿzðc þ[~ÖÿÝ»ù¿Ïûßýßúf¼ß)yo¼aÔ§ª,Œ˜øÁÿÍ—~·ÿ›"ñ£»ÿ›ˆ¿o–Þ”*7UWî½ÒKä£sß†òÚò|tîûÞò|ïùþþ%Af*–û™ðà÷ö¾ØŽ<ø½›¡kQ(JõG³ýùtF×óÇó¾¿ž´VÀOnk•nkËh4G.­MÎÑåFž¬]Ôâ[céÍsÂ³¼ƒÄÝÓn@ÉÝ…/	Û›ßÛ;»7ÙHüü¥5{äÈ¯·)Þ	±¬V ½tš—SA°œÎí¾Kü­ÝZÉKüyýfCÖ%>EqzS{K´k»¾”^ˆ‹uiÅú±Ý±¨Ö"ÄO´Ë<Òè¼-@¾MÄ¦Æ_ß=>•yŒ¿\Ìt»[c˜¥ŠqŒ8Ü£úÜ.	O«•4åËÞI˜Ÿ¦ì^MaÏ­¢(wüõïb¬td°ÙîI_=œhºì*êõ;'šJk÷/¡ú%¡þWjÕÚ¯f4Bÿ1ø£þƒù¿Jð3ýg¾è¿ówýg˜Ç••¯')s00NèÍ0&°þëõŸZþvýg•rü6óWîß.z†ßG‡·ÑÅÛäâÍµùÑ¶Øµy[ˆƒ·IKMø>uiByk¨ékÂrÆAWÌ[½dd@u—îJæv²Šf¹,|äâìqf´—/-;Ç¼%Ï¦f›ö=Ì¤—Ž³'*±¼°‡cŠ°—d·ÁØrbóý×=öÅ÷÷Åª×›ÞÇù–×ÛZ
ñT¾=¾ê¾ÁÝ#yùbûzé*
1{U˜±•
¿¨‘ÅàZ°sÕ‚2Ÿ
xÒKG¬€Å¤NYþé€Qó±ËÏl~2áNþ¸BÈ%N…ØfÔŠµXH¶'”£Ó=x+¿4ú´·.èLnKäòlÏfËúÒ²/ÿùÁÐÿ«MÈÿeá¹î·áË¢	õŸ'óø?Vƒß9ÿ!x±«e8ÀÝöD@‘ò¶iÂ[šq¼œöEæ°W‡x:z›ÿ°»ò8ëÏÍ¾­ü`·¢[eµÂ&öŠÂÚäÊÅø¸$Xå¸=0f‡ÚÛnäÌuOP¨Åy¯fóíBw×ÞÏÔ]Üî‰…wiE˜ÿøU4áü‡þúPÛùü¬û4âüG¡ÿ£64ÿ!þ«µò‘Æ°÷µ^ ÿÿ×Îÿä“ùØÿR	ÂÿÏƒåk5hDý}ÈÿÑÔ+ÁÏê¿âmÿ‹ÿmÿ«5ÕÛšæ¬,ãÐëÉl¯_Ä‡dxyðÍ»ÿ«cÚÝÿµ÷~ï«ráÇ÷½¯ÒÊLîþ¨È·±@N$[&iz6òÙ”²³¹Ü\¯i¯×¤o×ÊñBîÝ+×ÈGK×÷Ê5ò²ºvÁOß^ž!;Jæ»Ëƒ¥þš…+òã.—‹N\ó}‘ºÊ`Œ½å 7À§jaÌñL²ÖëQhöÚ­ÌM-'Ý‹’I$"{á~VW3£hoki~Í¦â"kÏLžM·¦iÈÅ×7øòuÿ«üÚ(<_v_ë½A´JmÃÇîêdP›ØZ¬tNÇxZŒ›l»±¨AŒà‚³ÕÆ±¨êÆƒUëèú‡––ð†wèvª³q¨wÜÌvæ¹¬˜£ŽD¤•+o;3äÎi8´ù”%›dÕŽeb'Õd†‚õ¹ÜË#.Á2ÅPÜ-jÃêëÿü2î‡Ñý‡=ñÿƒý/• VýçÝ®B N@üÿµõ_#øŸ$Àÿ»&4…ÿ!P þÿÚüñ?Äÿÿ]4Bÿ¡Oú¿ þS	jÕ°õµv@üÿµõ_#øŸ Àÿ³&4‚ÿ¶½Ö„FÄÿô“ùo˜ÿ©?õÿ¹Üæ¿½ïóßÚž=öí"‚{6ef8¡çQð0ÿíÙÕÎ¥b½Í—ÔËì÷mÀùØìwömÝ+òŸÌ~ßF¿‘_˜ýž‚sŸýîßç¾ïéä×æ¾-"Ý:–pÁ”s EZoIù TÂÑÒ=vçÜ
3û+Tó§VºB³´›4/®ü0(rµÜŸf$_°‘{™¬=Nµ\ßÆ¾‘Î}ßÇ¾‘'sßž/_V©À·ã”w"µ%Ž[³÷ÔÍ–×âÓYš*£MâòÚ4»ð]äùÜ7ŸNÂs6˜¨>f'Îj5ÆP;œ0d6é‹â6F)¿m«Ì)¤{ý©†ß_æhaIÖN„u˜Ë°5;®{®¶ÐÉv ËQ{wÖ˜$û:	ƒFè?¨ÿ×†Zõß~Y@
 ^@üÿµõ_#øêÿµ¡)üÿò² •£ñ?ø¿Õðÿ7ðÿ·zëÿè¿šP«þËÂs±ßìBˆþkÄÿ_[ÿ5ÿ	ìaþüß+B3ø? qQŸeæ”p$ÎÐs?âð"o,†bIQäsÞõŠQe¥©ŸõÙýÓÑþÿÏúð;ý?iú²
é‹E ’¶Å)²SLÚ£úyg8OÂS¡›ãýíâÝÿÓXG}ÇÏúÔiá-aë°E{{§>‰3ÄÃ¹N¢Ç6=ôta´¤|Ãµ±"ïil-¨³51YçÛœY1:kÝ¾Íe¨”ë)øþ*špþcä“þoð«ŸÎÿàóÙhTqÿ?ÿÑÿUFð?ýÐÿó?¡þŸÆøø¿nþÇ±‡þÈÿU„ªù|>š…ªøÿûÿ«àÿþàÿñuÑýwýT>Æÿ0ÿS	*Ñ0äÓX@üÿµõ_øGŸø ÀÿU Rþ‡	ŸÆ¡ñÿ3ÿâÿ* þàÿþàÿõÐŸ¦ÿÀç£±€øÿkë¿&ð?ÔÿëCÕü>ÍB#âÿgþPÿ¯àÿþàÿñuý?>ÿ¯ýýO‘èÿ*Ðýÿî³ õ¿êPÅÿ?åÑ„4Ëb(±8~“|}}D1aù>åaë±èõ™€ÁÑ9‹Q¸‡cÔõ
ÆrL÷šÀÿOæÿ)’ý_~çü¿Ò¡W¹Š…†ByÓÀFNœ<—ÝÖ‰;T*ûÌ['Z:éÛüÿ_—­nU+ä£e+˜ÿÿU4áüÇòñü‡þÏJPÿCÂ¯¹¨êüÿ‡ý?pþWèÿþèÿþŸzçò?Pÿ­Ÿ~þ¿|¡í§©¨âþ ÿÿ²ÿòÿŸ&ð?N=Ùÿû+AEüÏøêÓáùLÄb$îq`Þõ2I\„’8ŠÓQ0$ÁEÁøt@hès˜¢6‡À'¡	üÿÔÿâÿJð;óÿG|g¶?hƒÔ_ú("Ïæ»éØl½Å!ÔO>= ´hŽ'3!|Ëÿ?¶«üØ­‚|¤]åÖ­ùÿ_E#Îô‰ÿ?äÿ+AEç?´ý6Uÿÿ¸ÿ—ó¿
@ÿ/ôÿBÿï×íÿm‚þÃžå`ÿ_%øôóÿí`ò·™¨âþ ÿOÓ°ÿ¯4‚ÿ™Çý¯ôÿW‚êøÿíÁI 8jð?ðÝü£Oühàÿ*P/ÿï—ÔààÿÚù{âÿþo• ~þýµÿìþÄ··ñ¨Šÿÿ®þGQÄ£ÿõ¿*ð³úŸ{«ÿÅâ÷ú_/	rÚ]Qo¡wïlÑõÃZ—ÿúúŸÿöú_Yªñý%šÇ`5\«ñù¾ªè¯ö !÷E@?îjeqqð–2½ßzžÕS&oéQY˜£óòàùA–(á˜3±?qHÖ&‚ÅŒeögšMvv²"úz‹s¢åõºA^è~cg-sÛ–QÈ.ÿ^æCnu>ÁãËŽõVç^þV­[NÁr:|yë	+TÞr¡4ÄÛÒ w!Ï–…˜ˆ__;vº9Ëªë½ãë¬¬‰~û„ö£±/&<M©I@KDýæ¡ ^_ÅF³¯šl6Ñ—AJý{!uªu¾=·ø^/DÞ	8¶|9ó6C½š¹ˆÌX½¬“õ‚Öq‡?/ãÙÙŒìhSjqÿØë!¤HvVÜ¾—ÐGÌ=ÊÝ1®'~·3‹­¹3%‡1åÐÿº‚a3ôßƒÿ/ôU„úõ_àö«MÐOú¿@ÿUèÿ‚þ/èÿ‚þ/Èÿþ«5ÿ—…çºß‹¯ˆ&ÔžÌÿÑ
ú¯
üÎù¿Ü=,Ýd¡øUÚs‘Úé¹Á\ÌÞ^1qkÚÎ…2Ý[Û·ù?›‰gjëØ[<Ïs‰ìökrÙK¬×u)$ßŸGò˜š Ä˜ñ;¸ÝžŸÍõå@ôv¹îûªk¶ËM‘ŸWå²ˆ&§5‰Ãüß¯¢ç?ôÔ†zÏÿÛrºß¯&œÿ(ôÔ†Fð?Äµ¡~þ/Òx»ëð?ðíüOÁþ×ºÐ$þò`òÉhDý}ÌÿÑPÿ­?«ÿJ’(ò~ÿ{ýWßº›n'ÙóvºVÙ±nÆ¶1qþ(ÿï·Þ¿ßéÿý±Þ¿[ëò¾÷=[…;žwä`Ýõð¤Ëj’´if£ë³aÞš75ñÕÂgˆQX´mÜ°˜tö§Å01ˆqÒÆåÔ!è²¿GÁ‚ÓÐÞ˜6MC.J)~)ån•Z¿YCyßÏ÷¬Ï]j[R‹•Îé/£C‹q“m7Íb\p¶Ú8Uý¡YT–|9äµØí.[	'ç¼…iüQÚ/æI¨Òk™o™q·¥àŽkóˆr¾%jUp+S9zgb)Å=m°ÚIYà¡OÓ-?š`–YúÉú/ã~Ðþ5¡~ýçÍW)$ êÄÿ_[ÿ5‚ÿaÿgmhÿó·‡ÿá…€øÿkóÿÏâqq‹ÿ¿ÍÿYS½­iÎÊ2½žÌöúE|H†—w¹!7¬¢DÄ×€Y•K}ì\dÛ¸þ¢[>@Œ®…+…çÎ®±0•OmÙ5ë5Wp2LWš<;#S—Zxsá_dÇ´×oNŒÞ²|=)~üš0lie&÷ÀùYäD²eÂ¦gs!ŸM);›ËÍõšözMúv­/äÞ=s|4uqÏ\ ·Ô…ºà§o/Ï%óÝåÁRûß#?Æþ¸,æû"u•Áþ{ËAo€OÕÂ>˜ã™d­×£Ðìµ[™›ZNº%“HDöÂý¬®fFÑÞÖÒüšMÅEÖž™<=šnÿ:ö¿…þÈûßBäïbÿÑõ--áïÐ&ì TgãPï¸™íÌsY1GˆH+WÞvfÈÓphó)K6Éª5ÊÄNªÉës¹—G\‚e:Š¡¸-ZÔ†ýöž%¸q#»µ×;;Óöz'˜õ'“ì¦—£õÌXC ~dË1HB$%~$~ôs\Zh’I€@R”=[³‡TªvW%U›”/©½%•ÜR•=äšlÉ^¶’JÅ—T9¤¶rKrNº¢(J¤4ciÊF«J¯¯»ß·ûucõhcù‹Æ}éô\ØÌ”ø/ïû_W’®ßþ“%Ïù¿¾äùÿ_nûï¹ÿÜ©ïxëÿW”žùï}ä:ÒsáÿŸþþ··ÿçŠ’÷ýoïûßÞ÷¿½ï{ëÿžýw=öŸýi8o
àš’çÿ¹í¿çBþ{ëÿ×–ž+ùï}%ôÊÓsáÿ{ç¿][òÎóÎóÎóÎ»^ÿŸóì¿kJ×oÿ5ÑÀ´tyÞÿu$ÏÿÿrÛÏƒü1§¿ÿIsžü¿ŠôÉ.ÆEd)©ÕÂ’,Å¢RBt•­ñt5ÌUž­±,!ž‘k´¡k5^FÕHÅ¢V	‡÷ÌÏ‹€¿ÀéyÿÞùŸ×—žåùŸåÈn¤¤rZ´šÝÙíDŽÀfŠ>*3y‰Ùß,–ÌíÝbaµÖ\A;Vlqxþç`q o³Áµ^}Qî’hôëùÎQÐèÖ›­H5ùL¿Ñ©‡$)ßë)«á£¨Ê.îUÖW-õ0%)[éàn[¬Õ!¬¯®ÖéýkÛ;ÿsÞtqþWt¹‰¿{OJíÖyï˜1ÿÇckï$ÿ³a&Âyü‰Œ8–ÙKð>{ BªŒÌ% ¡,t£ÎŒëk’¡Ú–êh	6d´RÇ4á’Œ,--ÅDÚÏ˜ í7dÆ.€´žjèZi–S„~¸"Ä‹™Ä^BØKrârYrpj•.]N)X‹›b‘\å\Å„]ª£–yüf_„æ¹%òÏgça¸¶¤)KÐl@¿ïO¾
± ßO¾Tƒ«¦¶œ‰ïPANÁj´ªáÔ‰ ‹UÉÄ¤j˜—ªÕ*ÍEéˆ")‹8™–b’$…Ã\Eèh8ŠBRU¡Y&"…XVÁ†AŒ–6” ¿
í—KöÿNú•ûvoôôV·Æº+0¡ñ;hRÝO¶·9¸4okÜ!Ð,IÕ±§ImL[gårijù)€3H×-1?ýŠI±ˆ©/%æÅ¢ÝËRYqSÌ.+¨Ú­Ÿ–)•Å¼LÅRi™ØgB“ßR¦”ËéBr™PÉ,Ð•Lv
39]mŽ¤¸¿Ž4dªf ÚÂâüœF%„l®´žI.œÂ73¡“™âiˆ©ïv2¹¶+éëFSÕê{Šj,Á Þ±‚u½#Y iÈÁºj5ºU›žN×IÆuëÆì˜ÍiÂëô4âvÈû4©»ëØ3ö{N¿u²‡ðÛ	¯ÑgˆáIšŸ;ƒìI¡ùi>Q(Š„Ð±µ˜Ú›Fí6@"-dò‰Br4)Æ+©“ ›¹=l¤­2ùòrWS—‚Á`C7­`O2°¨¹ÆFÀ'R»äºˆ	“å9­>	;d¹3º“s
·d!±†‹¦¥r¢_É¤öòby«P\ËáÖ-yiOA5©Û²¦¼ôÿÔ™qæ9Â¹NíëB9}šqÂ#Ž91™ÂeKelÜ:ÿ“BYˆ%q9¡wåF2~|¢PI¤“q·MîÝ°ƒdR\©.ñ±(÷L¹”4jº‚F
•äøå¦bgcKrÙ2ºè6fNŽ¾aI;ž"9¡³X}DUK'‰ìé¥Á:‘€˜ÁéÔ7]Lü%ßK¬Vsº°±Ùµ+¨ƒ4ÅÜÃ†à¨;ÏÒ¡ä™K#DDÉeºwáÎBÃ*9D¸@x‚<¦Ê)*ß«³ø–…»3ˆ5›Ô"m
¶Q»J˜cí9£t‰ùŸ©&Äyï8ßÿc¸ÍNúøÆóÿ®"ß]J}þù_ÆþôÿZúëïþû?küZ‘ú‡ÿùôWÿùéï~ûÉ¿QÈ€OðcÀ7_¸ýÂÝ7þÓ_ýâk¾—-dZ¶ W•·ßçÂ¡hHA-q!%ÆÞG‡¸HU	11æÃt•áb<'ÇXñQì´°|MŠÆX%„/x¶JÝ¥Þ|ôÎ/>kûàk¿Œ~²ð³Oþâ°_ø”ÿÙ“ÿíP@ƒÑÔïÑÔ?¿^N`Q‡…ƒÚm›Ôß½Nýèu@%\²<~Dý÷kÔO^/ÍKýþkwÿëø*ÖµÔÜ¡>»CýËðuW'SÿxcVÌ9µGÇ`$W«…F4ZY´Z«±4âÍýJ?ž<uÆÑ3?c7—‡Ç`lTC«Z®ÄOÆ’È¹¸>Œ%)“80pþpKçF{b.Æ÷Ä8á0ÍþJß‡9ŒãöË‡§ŽÃ;6ˆ‡vHÏtÀ3ÎÎ?:47X&¼OF›Ms1s´¶:ˆ·•ìA#˜šâ.oõË;s9²òL%Ùi™-d	+…Õ­bz±Y£••|¯Äô{(U¬„1 ßòµÜ
=åìŒT;'DíH—UÜ?9a'â+äFÆË”àJ_ gk	'¶†3õzJ²ZS¬§YKì–…é vWù~CçÂ½Ì¶>ÈîhÍZ£sÀyžfb`ì[•}+¾#‰õœcÑ´¨f+ac±Þá¦"'wŽÖ²Ýz"“ÚnÉ>,õ¶J«(¤´¨ÐëTÃåÂ¡Õ4Ö2TÁF-Ý4KÁsâb|<“›R„›ä±Êç»m3¿8P‚ñÔ@ßŽ¨ºØlmœ
*“žuPYª,lƒÊÄTl°{tr÷9\&¤áá2"›o€l{*`?Ýó¹²ÜÏïgØ\9CÊv‹äíÛyô0líÇ«D2\V0€¡dµ\œv˜¾ßßÂ$kI[¼0ïã»à¼)}ÎñT7ºvß`RÍÃR9·©g{‘ü¶º³¶µÏ[ádlË«ñ´–mnmFZÅJmGZÖV$¥¤ª|.²Ùíô“Ñ|)’1sÊz1¼Ë‰ƒT½¿¶_.Ç³9s•I:‡Ê±M×“Bn|ã˜°/9òQy—éo4s‰5!o»R7ÏÄcÀ(f›ýµöA§]BrF*:±Î©ì*Ÿæ$©›ôQ³ìH5º.äÄJ"³‘àÌµ0HˆõƒjyqQé(ÆoÅ‚mw1’Ìð¨¤mUú›±^B	Ö3õ¿ÖÛùÕ¢¯èbG3ý\,Ò-íÍ\z]¢ÕA‚‹EzJ¾RÎ‹¿
^*¥–ºAþóáÕšÉ(%rú2Z©±·]fŠ±øþÎçwéV1¡N«öZÔÎ1æ¶H# ºçiT°C1Ó;—V=`r;æüª'ÚOã '¢twQzaõ†úg»Q;Zw5º˜Š¬vC‡q6»¸ËäC–ÙÝ*WäýA«·’Ñc[i¶©TÖdsÛ«‚z hu+æV*·[ì·”Øú¶Á°z§¯K5~#<[ý€¡þ¹ˆú‰ìêBm1!Ä8Z±Š˜ïmX³Å¥’°Ôgäˆ’	÷CƒS±¿#õ“Ò=.V`@W\‰…Óæø:ß/˜ñJ²¿¢ílÕcê€Y«Q†o&2Âv6"ô’­|ºÉ"1UXÛTÃ•ÝJÁ×B×’R­Y«%Ú½h¸-žÃewoØ§š¾ p¯¨ïQ¿qóêê&uÿ¾xó+w_¦n¬¿Q|½ˆ$ìô^¤Ä–¡Zó—xÛý½û>x-Ñ4µ²]÷u½¥Êê>õÊÍ¯R7‡¸ß}#èÂÝ	Ø [ÓY|¿9j7EÝÄ¸¼D½H}e„ÀYÅ¨?yƒ`kgQ?~ƒú÷oPÍqR¿üÖÝ?wÍçŸÞ¡~r‡ú£;£ç$ó¯fŠ2o#¹·‘ÜÛH~ÂPþáL¦ñN_ôN_üBŸ¾xÊ&þ›™<áíHòv$y;’Î5}CÇvéê;Ø¼;f—¾J½2nº
±#»qþ2¡c“yîB#ø·À×-"Ó2TÙ^Á¢nï~|ƒÌæ"ÍìšåAQ·©à%Soé#¸—,¹QRõõòMpûÉ“'Ì›OžÀÌwÀ+6LYm#½kQ¯R/YsÔˆ·Á7ãd	cSj©Šm‹c;þØ
¿5êÆ¬ï¸Á#7cfØûçÔ3ìì7©W1Þß~ñT?½n§%³¡ju¡U×qE61í+2Gíôƒ_·Û‘”,É-P²Œ®lu»ënþNßgÀmwpE1i"“â©»àÍiQ6$‚âL_äZzå&øŠóç¥§IOÿ9+ö“¤™ñŸLhbýç/þûJ’ÿéÅzñŸ^üçYòâ?§sÿéÅzñŸOÿ9w˜§ÔéuzAŸSšÛÿ³yvÅ~0zÇŒý¿!–™ØÿË²–õü¿«H÷¾¬ªZ°*™ îAñPµ ®Ášj˜D†¡`ÇP5J­ÖP–›ì)bP1± xð~n!¹¡CŸoxa?YÂÒí$åÀü
üøcìú`šûÐwªX¡cË¼¥a†AßïX¸Œn8e–àFj=ÄCªb×É!Y,ñz¨¥wˆø€m¬hN×.:rï4Z'@I'0à1 ë’a¢=Á¨wI¦ÓÎ~ƒxkÀ…{Ð_· ?|*:¸uK–L¨jøæ–ßß@­ÎCry+-f×3ù•‚³¿ä¼óÎHØ‚´â^Qœ®“›7÷l[c¼Ü­[È”düc6Ôšn)º†¦ Þ@­aD}xìƒËËÐGªó¼­ÒlDìÑ5AYHÆãmÈ•\uˆ_þ~—( èoŸJÊª¤<”»†AzÛZ7€8 ¾…PV ùÁì‚l ¤÷J…J1!~@ˆ±yèƒo½;}_£;Ñü3±v4ÛéÁÅð{ûfíT¨e¢—¶K’î±{ÂVjð$ô×êc•b´½¯]°H·ƒ©€tp_ÂdXÃdŸ>Ö®Ð!Xhé®uS›MwzÍaWöqï@liØhƒ-ÉÂ¥†|ûª¦ÙE5<œJÁFa±¼WÎäÄB¥¼ünK2È›´.Q­ï‡-ÌBR!Ah4@'J>†&Â¶‚bìFÈ×F“F·0m¹ó)ÝŽØµžUé;:9dæÌ=§q|†ÏãXš.<”*üúÔéâ’YŸá°Ká‘™Ã‹v¡ØŽÄÈ®êªvJ¸ýcœhqs»#ÏýZê4³Ó7WÇìtýÕÉ¦»SæE‡N\úÌ#‹¸ÎP#)íóš"¦1c]·"ü’¦¹í?I‘f—0gÿa#ö_ˆc½ó_¯$=­ý÷ôÖBàòæÂ=Xjt-[ÉÚu'¡:rXMpaýŽñ0P[ï9zÊöP‰à³¸g´¡ß¨ÁÃ—ŽAIDqÛ›61€{o´U¸ðàÄC"<ýoCÿÁCRÑŽÞ5 90-ÔÆšjzÊ-$ióKÓù×ÿl5:Üeµnèd6z>10‹ÿŽŸàŽ€{üé²üïhû¼Žó{’Ú²½0p!&ÃÑïÄ u()à»îFzéÌ47ÿI×Ò%åóÐÿ“ç¿aýO‡<þ¿ŠôÔú–ðQ—W¨õ×»Œ´¤º£s%²yš£\%¾±­:G>W‡”žw-lF™)³JÈHë]´ÐY«Ó³Þ5e~büçäÿ§:œùÂçÿ²4Í1Þù¿W‘æÓÒ;—›ýŸ=þ<7yþËÓžÿw%ééäïY8€Wâ	â\É‚mµÞ°`u„Dk0œ( ûâlop–C		ã<Ç“[óò¿ãþ­#-ÜVµ„d(s‚YëáGøŸÇRŸÐñÿXoýïjÒlþšzŸãŠÿÈ^£Êî%
¹õB‰Ätf3Ç§—'ž-/<è7T¹1š»~h¯Í§ã)7ÜtÞÆÖ…J/ˆUÓ2!~,A7þ¾×£GÐià®˜Žû^óIPÃÖÖØ¼÷TP¿XñÇPê7¡% ï„k°À¾Ëð¡³ÆøØ‰¹´;aá·q/@æÄ¤úhbý~I7ŒÁ#XÁ¢g8£iÈÞ3áNÆØË-îkM,äð-‚¤Y|€¾«sV7íËáJØè5“¬ñ¯o´TÒMÎoäC»<£
œó)då£!õÐÉJU³][«¤zG²¾[·f8ââ‰k½5·¢:r‡–ZSe²° þï¾ÅÂ
|­v‡Ì¶;'°oêøÈ*B”¾%è³ešï‘“iaÃùTæ0|?ø`ØEA_×hù †­ùD4
YGòÁÇ6è‡n²„K»…Hý“,vò£c¬¦D½ú»uÙ‘FãÈÀN, ûtÐÅ>P¥˜õß°m£"¨‡™øœ!ß~¢aÎJ‘óÉÅ£a÷µÍN&Iž»ao£¾vöàà'!š3 Ü3º÷ÖÄ)“´—Ž:guìø‹ÃIR•F‘pµFË‘hˆŽÖ¢1T“¹jTŽql…>U$Zq´,1Ñˆ«2IŠIÇGöÌ& »°®kS­kÎg§¢Êm¡:•ae¬µa?è×àH—¿o>ay¥›]‚ìÅÜÓ5–=»Øp9¶3S¡¿{\Y˜Å5‘.&â¦InÆˆ…äãÐt7(¹÷~'®ž¼gÇ Áå,Õ¶½@>«,|ÜþébÇ&Ÿ—Î ám×„Õ–ÙHs_ß9è‘1|6osÛCÂ¾Ä;.îÿ3ö÷<ÿÿóOÿ‚-0foÿšµÿ›ÿ“ç?ò!ÞÛÿu%éHaûÅ™xß °¯_$y&,"›.” ¸G¼ìõä¶?«ÊH3‘?£`û›aÈX‚BGÂf·ŸÐúŸ]úöžmGq$Ëí~Xµ¼+•V+í<YÕ³£îÎ®LÛØ\RÓÒØ`À	†ä–$H£VØc0°ÁÀ¨¤ý„‘ökö/öoöu#ÂL&]YU€§*ÎCŸ¸Ÿ8wClo÷©h\HôéœÑ·&¢³ÈÌäDoV²øÀD\lÈÂa—s÷•»érT~]ä_uÒòÚ¸ßÑìÆ]Íäœ1°&·ôS·ð×na|Û˜:^Å†aà[Í"¼ûlÇÇ"ÌÎO.¦ApYOÔÜ•½3z2¾d¯¿‘·ãýè]¼‹šxí-¼íÉ©ö¯ÉžtóšìÁÎ=tÂí{2ü­	RS í
¶¥»;‰„ßÐ×É¿Æjj[:”{[	n.òµ[;‹yˆ/¸¨s¼¯®iZ…uh,lÐ¾É¼PS*¢›œ>ÈÿœÆ Cˆ9™€	æs°F¢BØ/on.Ä-Ã;`_¶Fm»XÕ«z¾CÃ«Âî…çíû''Ž¦¨CÖš½éæ Ÿ~ôªò3í‚‰‹‡ßÃ‹~Á¹ê±3	öFÄ=õ]PÁk^8<¤jØÍ yž¹ÕÃÚ“ÂC@ïf+p|Òšc½~VÇ:D|{0c„·ûÛõvðïß_Ã¿‚üþýÛ"	Ô^Ž†ÔÚ°}8·K`CÁŸîÏ‘—)ìó5²’þ&x„Â6¦ç†;EmiØëë“míµ}ºú}ÇePôÁ‹b¯é·°ä¹6$2”èŠÃº\
Õ¼]¿ß-®»kê2÷è|-W¡‘bh°ÎÑ.i`þå›Ó—í	<}¬ã»ø¢ÅGé€€°èhŒ‘Þ0 %X‡
æ[•cNÙl˜>`Ûë!Þx`w®ŸŸÛqFð_kdz¬ÿì½ÞbáÉ:‹‰÷ŽÝn»Ž³€—ßz.Q/_tÔC|Ò?à—~ü?Ä>Æèª´&=cEÿÐ@ÿ¢‡¹;ú7Ð$"Ò„“£øÑQùa»Æ?^ÁŠOöŽ6b¿ƒ€¢‰™8=^x4!¨èöÂ…§ÒŠí8ð´æxƒ_HÒÝÀƒ¶Lsn˜w0:L—µý¤£µ‚"m8‡:j×·vøpçuÇ¶-¬ù=ÑÎiÐ8:X¶[z©	O7šö[ZØì¤n÷s8«÷ïáO-Óû÷°F4pö$Ç©…î¹Ó¥pš;Ý­4ÐuôÌ¥…·1èõð	ûm<¬ò9QðpŸ,ÐBô§ËÿÏc^’1_ÿ!õLþ˜$‘ÿÏÔÿ}KýJýõ»oÿðÏßý/þ¦Ã¿>Qéÿô#¡1:Ïs™t_gu–Ï€¾Öçõt&“ìkŽçRÀàYƒOò-“àuÀg„L†ÕRiÓÒ‚ðæ¿¿¥þþ-õññÍPÿ"NÑ¤Ý¢Þ|~®áŸþðGŠŠ|ÊáßßüÛ±O<üá¾yó÷o‘ü×7ß}³Çó19¥>27Õ‹9®v¹©>ªï—^ù >ùüßs´…e÷àÉÿ¸/b¿tþy–êÿ$ùŸÎ:×4&4Ê3Ç¦™P¹ûËõe/u:˜Í~Åqj¼oç¨m€B÷nZ¥·;?Ô7‚Ä3ô;gáMÎX‡R OLóAŒÙm¬^€*ˆ›«(Òý]Eo+¹§o1öÒ9|Æý¬ÈÇ©þ1|øü³L2ñÔþÃ'R$þã,pý?bH¿eÀíÓtèìþõŽÎYý¾½‘4]tH,\,„AaÊ¾1H`eÄ‡Ã"7Ôõ0*àÒS0‡òŠ‡ÝÃxÝýñÇFÍ¾ö¸ÂAÆ
Gèå>åMX¾/@ðç?ßÒ?…OrTåT8ð>8|—ÆóøÓÞ¤±{ùÌÖá+Ï¹™ç(_hq×j¨È}BÔotâöH»»jðÈÔDž~öôÀŽžjS7•Àía?v{¼Õ
…PºÛüQë°iMi>!Ò)`lpßCQ½¤ÃÓ¤°&‘Í¾UŸb«?™æ­^«ìà³ÝØÀ„V÷P”Fj¬ãÁUB>„¦vÎÂîÑehÔÅNˆÏÂ§¿·æK[x[€•?ðœïµUX·âÀæMX°5ÞÑ:r$¾§Ãýí.êatÂ9‡‹†[§7:†>¤lS˜\›X©¿dDÚ½s`¿C‹`ƒl$](PcE³Qñý®Wr;(-YÊàgÍ·ºmLš‚S”ô‹Þú]Nô¶‘ƒ½³C º¥?1w^˜ýnÛ!o1GÚÉ>:(–­wÚË-ç¶#HþºŸ[Ýšû–®;£*«’\§ö‹j²±\ND_>{!ƒär/LüG¸¡}ôÔ#\?ï¸ÒD8sdv|Ba¿>:XäŽ¸ÕMcÈíöƒ"zæ÷˜°yî¸.ZAÚ„?¬)vü]LBúÉÒè†ºil=AKëLBö×–e<”Lh,™l#ËŽB£Ãa¬¼láƒY÷pï M*Îƒw²GÎ6•jeïðâ]Ú™°!­[ø„'Ÿöæ`â‚à5gŽ‘N¦´¡KÆÜ°±f{Ïpæ¶	8¥!ß]ýáEÓ(¹| ÆÝvY¢tJÁÖúºÏY·ë.äù†€·(/ý[¬Ó;ýÔÎaA¨JÐö.åz4•áoå§Ùvg±§Ã4öAÁiy1ÑÅ»Ä;¡ó76  +Ðzã‰æÂ¿¥9÷;J¤ø¬‰7wl÷‰ñe»Œ“`lødà-°O"»KÆ{p£€­ïFuæc°²Æ‹ñ± Ú©1Ã¡ ýy¤÷˜¸Uˆmk„`¢­‰œç¼ÛQ³ÒÚƒ“ÌÕ¶üy»ª…"œ?°·DI ¢õÆÜ6VoßÅ}Ç®÷$.l¶6œIÓªíÝ=æ¾aûI÷¦»¯Þ?ZÜÓar'^œß¶ÁÛ[Ä–(¸Qá¡‰à;@rÐíàµý|ì»ŸåèR8#%tNn#-Ksg„®Øaì¦‡ŽëÐZð op|x‘ÃzÝºD•jS¾ÅÁÊý-VXMï7Ù¶õ„L³\
'efo3L†ÛSŠ¨sNÈm»è ÿ¥ [ˆD³
”ž…îDd
Úy1Eûî"gÈ3L‚¤I!Ý8ä”_8>¹"÷Øy®¹8ÏsD%DúOÇ$ÂS-vt¬¹àçÒÿü>ÿßóÿtÿožÄÿûð;×ÿ¹Dq¤O^ÿÃ
I²þç€W_ÿgåç¬‚KdýÏ×7×7);³lMF'j#bÿÁkýäxØÙƒ½À°lþG—OÔŸØ®ÿÜq>hÍ~éù?(œþü—'ãpŽõÿúŸdý?Äþsó”þ©¡ÿç€sÑÿßl¿ôð¿z ôŸÐÿËÓþ9ýOú¸0ý÷l"\ý'ôÿâôŸM>×ÿp„þŸb@ÿƒv¯õù—8¿q‡sÑÿÄÿ°Ã¥ÿÄÿÿô€ƒG%¹ Th”fMÉ+Y±)!¥ª¢d«ÃlV4
¦è+’h*5éÎyHdÛÙyrÒx¬¹ÃeZ2k±$™æl0Vïkµœ8”8µæúT¶ÖÉ=ÔjÙ¿{hmä¦
Ù–œ•ÔRË» Ý]êcaÚiÊmUªágÒJ­´¸üB‘»kªÓ†à±2Ô6rW•ôàåZÓwµ!ØF!ïé…•]W–ZSî«ƒëˆ+µÝ+¬6T‡“Ç+‹FÞgV•È©ÃÎJÖuØ°l”Õp…
Õ¼»ÊnÄ;É¬<Hb§)ÚMµ®úr0<Eö§¹N{5íŽ3kmlÔzÇÏ‹øY‘’}¶Ùióf}r7ÐÆ•©ÎU–j=íƒ—s9©+uìTIp.ôUyüÀwÚ¬¯Z‹—ñ(5?òe¿S,9]e3d²b­£„¿sbMÏÕLQNLË­ùhÚÔo®rËQf–äÅÎT3™"ËS½œ6k[JÑíéõFiÉÊf;ÉÔ]¾]Òëfi˜Š›—™õn¥²¶ÊfrÊoøzµ	*®Zp|*gÂ®Ö™{±V¼‘D¸¾fÛgºwW«á¥ËfÝ‚Xkå%_•à^˜K¦œ—`ïÄ¡¨RhâŠuUûiˆ*ª_VüÚHÍ–D¥Ê±xcš÷F¥°|rZšÝxó;CÚŒM%¦*ÕD£êVøVÉUE¶6+4T>#AT"£‹ª\Ë*ÅÔJkÍ29u°æXíñQKXéžâ›å5^•WÝ~c±È\Ê£nI´$¥þØK°“L8
Û3G¶wÕËˆœcN‹Â•±˜%F7ýÉTHÍj¿üBá!WrÏOÉ¥OðïƒxðÜsù?Iø¿s@ø?ÞïbþK<ãÿHü÷yà%þ¯‘CüßÕŽÿ“—M¶ž‘†6Y©t»ž¬s_8ÿWì¼6ÿ7òó>®P’WÇù¾-H!&Q^u­XvÂñÊà©-“ø8èoî“‹	S/¤î‰•Ä•¯ºl%áY©n»ÙÒ‡k{™WœL»ÈzZs9õñN´fcµ•$Ÿo¾[÷í^æþqÎrÎÔw@_¨%+}5ÏøÏyÄÂXÓ˜Í£ “¨¨b§ åÃ(ú9Wn•[¾èËÒÍFœb>±ÆËŠY3S]Gì_eÅÏ *Ó’+ËÍc•sm¾Xâpã³zª§$ýÄ 6óý¬¹¯wj®QÖEÅ,‹Å%Ÿ©²ÔBÎg’;æSð«®ÔÊùùI§mf¬µðîÒ¬0Ê*âc9%.sv¥8â¹P-=XÉV·Uë÷Téç@ÔïgÇËtr,)a<ø?¢ÿ»Ä€ÿõ#c}éÉø
!öŸÄÓï?"þ|ÿç,áÿÂ/+Ð%¹³åÿ
EÑ”EURÒ:Ð¸À¿wÚxm¥ãÄÖjæ½žP…Õ•Wmúù«IiJyWå¾‘-ï{›z¾™gïWÞZœÊ0¨‹•¬(6‘×X4ìÊæ†¯^5¹ù| ô,{‘«õUYLb+v•Wf7­ÎBÒæõÂfÐ™®
âì~¦æî«	nzcøL¢¤,r³Éð~ •ýíülP—žð˜A,îâÿq1¸ðý>lsé)øª!÷?Cü?.± ÿDþ»Ä€þï?lvéÉø
ÐBÿ/Nÿƒ½qHÿBÿÏ±¢ÿ/|ØòÒsõ%Bì¿<—$ú¿ÁKößòÿÓ³[ûo]¬,ª“‡ÊÕºw#ÖÎcÊrä‘]{jóõ\¦TqØtjöáA]É±QÍfvTh{¬%î -¯òC±<Ó›¹øÌ’
”>Î/:œ½épéU¡)>œ¦\È¬»yÑ}´GÉí6„¡Æ1«bNAµ)s•U­èzEmê~e¨pjSaªM…k£²!.c¶eT{(iÈ–ý¹¦ljkËŽ˜²÷fjßo×Úu´ñ¸•ZêRÒ¾ŠŒ"J…Eº´’jla´j4Õ§¼LU­N©=¼dn@µëÍ;©8)Ú)»Þêw@I,åA¯aY‚šê¦ºS?—®4RŠ«öîëÉ./¯¦_6›RYù…l¸9d¢õkhm‹fNT_té“Æó.X¤$EÊPózyä—Æ³é¸aè
¨VçL6ŸT-îN(ò ,ž»ô™¢*·²J-Ë»¥Z’ÊÊæLkv>6¡¹LºW©œ"I»å?d–ÙÞ©˜¡”tÆ•»uÏÉ;òÈŠ¯fR‹õø ïc­³|&µìUZuñËõéûˆÿÇ¦žó$þû,þ GDp òÿ×ÍÿÅ‚þGô¿Äÿû,/úO ç"ÿÝôŸÈÿDþ'ò?‘ÿ/+ÿ?óÿ"ù?Ï1àÿt@„ÿ‹‘ÿ¿nþ/ôÿÉ^ ôÿ|#ú¯ƒgßÅ"’ÿ©!ò¿À>ÿfRDþ?¼$ÿ×pþŸñ.þ;w§UétëÊ³ï2ECp‡-_zÿ½¹Hü·®JÎ6þ»‰B¿©ßûÊ(µ¨~vì7
ý¦>/öÛ÷fˆ’WŸ÷½û¦F5ŽMv¤\z4r¯”Mén-{åÙà¦|ãÊ]Áó›³ÎÔ-±¯2PZ¹©íÚ†'æ«wµv½x5Ò¨Á&Ÿ¯,ìÌ_…z+	+
ðrÜ÷6ì›ú”¸ïðìYÊ•Í"çÉ‹¦8³1Õ½üÃ'—5åÑY—;“Q0ñ¿÷]Ï‡7vkèI ›ªG­2i[Ø\YåVr~eNù¬ÛÓsM©¼0³JáÑÖ[B,Û–W“´¸œjÉfuåæ%ej4eªÖWÓnãæKSÄ‚ÿ#öÿ‹Aø?Ïv‰
àR@äÿ¯›ÿ‹ý'öÿ‹A¼è?þI´ g„XÈÿ$ÿÛÅ€ä#ùßHþ7’ÿí²òÿ‘øO–ðç€ð#cízÎÜ Òÿ€Èÿ_7ÿúŸàŽ|ÿ“Èÿg8Ñ–åÐ#•ÔúŒžJ'˜t?1ú:¯¥õÏ%Œ+$Ó=Àè	žÑ›NŒÆ¦ È žR¿º§ÚÁ_.Äþ“üŸ—ƒ×ÌÿÉ0Š_.K%ÇºÉX#-Iu«âÓ`J¡mÛK;Ÿ3ôM½T›p‹0ÿg}¾ÌºµV¥>U[£MdSW›~œµ+Í0)þaÔZ×êÂZÈÛ†Ðz(rËÌÚ“–ã,šUÎà€.ÞäZ‹u9Wl2ÆØÔ£fIþÏ…8Üÿ,ÄþKòÿœNOÿIŠÏ8Ã9Öÿ3ä?!Eä¿³@,èòÙ÷¿HþÏ3Áyè?IñW ôŸÐÿKÓŽc‰þïBpvúOR|Ä
ÎEÿ?5ÿCôg’ÿƒäÿ ù?þ¡]x~ÄÿƒÜñÿ¾œ‡ÿ#ñ=q"ÿÝü_è?Ç&È÷ÿ.ç¥ÿ$¸'nùÿHþ|þ‰üz ù?Hþ’ÿƒäÿ öÂÿŽÿ#)>â
Dþÿºù¿8Ðbÿ¿œþ“±‚XÈÿGò0$ÿÇY€äÿ ù?Hþ’ÿã²ñ_Gò¿ñ„ÿ;œþþ×‘ùãçXÿÏ‘ÿy–Èÿç€8ÐNx&ÿ“üOg‚³Ð6´¤ 4Mcø4“êË¼Î€  ™ä3FŠI'ÓFh=”$8®—þö®­9QuÛžgþŠUGî—‡]u¸*"(¢¢¼ìâ.*¢¢¢þú­IìîÝ+Yé89ºRvú’Ç7æ7ç“I&Ä\Ú!ØãËPþÿA]$!Ôÿ%à3ó?œž·_œÕõˆš¦3gˆ#Tâáã1/%£ gÆfLžiC'3“
_ò?¬äMÖ±Ü?YÖ™œëÙJm9è~Ófb€¬RBè­“´ØNz(.ÏÌ^jŸÆ4ÊÈ¥àÈ=Ø·õÑçºöVäHGn{(‘*ÿñ^ÔâüGïú¿Oý8ÿ¿¥œÿpá_[”uþÿÓù?’€ó¿ÀüÌÿÁüÌÿUëÿ{pÿû_KÁ×ŸÿOÐ¨)Êxþ¹ÿ‡ù¿rPþÇ)ú¿¡,þîR2Qˆ²hÄ°æF‰¡”®Ï1,æ‡4‹²á_Þÿ„Çlè¡Aˆ‘¸ëCàkPþ”ÿù?åà3ïÿ‹¨1IV»d•-GÍ}{ƒ4ÆÃhÓlëÎSãæ¾Gô§yØ?Ž²{Ëÿ•¦ÞÜÐÑ@öò”‰äöô@­FDˆwwK1§¾f³£dŽM#w€í÷<=úQÛZé|ÛÙ²-Ž	”7Y‰³us)Áýÿ{Q‹ó{°ÿÎÿRPÖùcÿõDYç?Ìÿ×0ÿóÿ0ÿóÿpÿúïkÎÿë§€í¿®(ãùäþŸÆáþ¿ÔÿqôAýO ÿ—²øÿú+zWÿÃ±P5€ÿÿ«çÿ»þ/ä¿–„Šù·„Ò R ÿÿWÎÿØƒüÈ,5àÿç÷ýíŸøý­;Êâÿ¿íÿ]ÄÞÝü'øKÁ[ý?ç,Š|LÿÜÿÕÉ]KäÝpŸN˜îQÂäD>NïöóJöùà¶ÿKYrÄÇÙïì Cž^ü`È¯ýÌ‡;ÀŽºí·ÆKÎ?ìT"×%`oî ãÍC”‘ƒ‘Æ7Ý]Fhçl…/Ð…³~Ci
Z§P»ÊjnYÒ %ž}¼ƒq—Ñ&¼4Êè¸ž´çð¦dnçœ±[¥óØñ$vÌý=;~ù®>Ÿ§¯W¼î 3GŠPè‚Ç[!–Áô%„Ÿ¿caXwùv3Žû¡Ñ:ŒÉc±ónÛ	…sŠÄ*Ë“aõrƒi¹.ÆOX6Í™.4De%,‰Z<~Ô¸ˆ“çO¸ß4æóºlŠª<ÖPm»_+M6ØwÎ¾Ð˜Nµ¶$ÓHR»+$££ÍfL®óy¯Ë'Â<äš¡•õ†'‘ ùå.Íô6iï6ºÍñQ0°¦}Z;Ú&âÿUëEcõÐüßÿZ
j ÿ|´_e¨…þ»Ÿÿ¢h
ô_€ù/˜ÿ‚ù/˜ÿ‚û?ÐÕÞÿ-ÂSÕßŒoˆ:ôåÿÑ°ÿ¯|¦ÿoo˜òp¯ÉÃÊŽ™ØBöÎ ¢ù5GÝ­ì¯æŽ3÷)+Ì³ý‹ÿÏ”»Ý“ÇbÜo&ŒkœrºÃ­NË%ÎÍVâ‹âÑ!ÑEŒâœ0™4[Ó²ÚÑ¾1´ì´ ‹ÜïÛ¦Ì£Ùzþ¿÷¢ç?ÌT†ŠÏÿër ª¿ßu8ÿQ˜ÿ¨µà¨ÿ*Cø?Oâì­ÀÿÀÿ•óÿóÏÆ_ùò¿KA­øÿñ'AHÈ¢ý_§áþ¯"¼ÕÿmE‘÷~ö‡G|x(¦;>¢qM3—IŸeÃ?8ÿ[É?;ÿû¹¯ûÒÖ-{|ÒÅÿÞÖEÞÊ÷î÷Û£5Ó§~T½ehGq©Çogn©j!¸K)ìíZuÖ\‘2Z£ »ª Æ&ž9‰]mÚ6‘½©°õÖ¨oµVÚ0t9jë"íë†¼ÎÏÓw×¶maŠ:ÏÚsKw.ˆf¡fü_b¼‘[Ž÷{c¼­Ë_80Õ¯‘	Þ>ãˆFpìð0ï,h|JY¸šÎú”Ù
!Í–Š¶P‹OøÞðHÐÅþÄ5IA³—'&:Ü¸¡Hš*'žŠËÆú85¦f½ÇòJC-ôÆÜë?ð—‚è?7H¸ ¨PÿoýWþ§ÜÿÂüw)¨ÿó×ÿ. ÊÔÿß›ÿß¬ÿ¯û¿|ñ§ÿÏØ÷Vc£q
šBë”M˜$“KóÎÿçŸ+ñÿI¼{óÿÉ¸1C~Çûw}ùïßõ*ù[ï_QØ¦=Ø¹6Å?¾©äMï_kÏjGÁÄZ‹£5ÔÇY÷À“dªÙsjGK3Ä;B{Õ]Øcf9ESWã5Å¬$¡tÆaœu!±†Å¨¹ô´CÊ§V\hóáPèê<ÙB®µ¾ô\ë_Ÿm;–ÞaçÒ­ãîA8d;è.
-Ý¬S+ôU·×Û¢¢Bë	Þ¡Ú¤ëîï]y1¯Ë#Q5E2×Låxã§!ÉºgŽ²¹ælå4I¥BkeŠ1wƒf¬Æ¥ÑYjtNA¦dòÚ•ÕBç˜½…LÆz»ï¢ÉI$9æ£õÿµÐØƒý/ÿY
j ÿ|ŠÿÊ õÿ÷ÖµàÿW?Àÿå¡FüûA*@êÿGû¿iêÿ2 û¿aÿ7ìÿ†ýßÐÿýW‘þ{ZW Õ êÿï­ÿjÁÿÐÿ¯õâØZ6jQÿCþ[e€ü7Èƒü7È«¶þàÿÄ@ÿ•è¿ExÊwÙ6„ê¿@ýÿ½õ_øŸÀìÿ„ú¿Ô‰ÿƒÈÃ?¢°ÀGi, XÊ#Y
¥8ÎÑôXñ}Ö÷/$áÒŒž>íSGxhˆþ;ÿªŸà?uàÈÿ¬Ÿ™ÿ™Ÿ»Ž6?&BÖo*MƒFò,gÛ3w\§<× E{®è“MìµÄ[þ'ËÖê@fOžíÇ”ÃÉÚè$®÷˜¸n!ÓY×Ù.&Ç¾yðWÙ,]¢—o)Îc9‘¤Q·öOaxëfLÅ­Ý~58ªnÐ†üÏ÷â7ßÿÙ6·¯)àõ¿ñÏõJ_ïÿ@ÿ}=¾âù¿^ðýýù|xþe ú#Ì@þW)øê÷ÿõMsõEÏÿüÏ0$ð¨ÿ3äÿV„røÿ9×áµ.TààÿêùÿAÿîÿKAUü]üUõ× þþ¯žÿqôÁýèÿRP%ÿ¿,~„åß¢,þÿÛü7êuþ‰¢àÿ.oÍw¯ùïAïgþ[Ïˆw[eÇ™;ˆã¤%ßå¿yÒgç¿)oÝòßDüõ°tV´ø[¨ºr›•^"õ}ëÊóÈ7òQß÷mäù9óýó¿(	Šà´°µ·îòÞ^7Û‘»¼7=Ø&…¢TÏrv§ý¬me¶ëƒž·š4VÀvcvcÃäh çF¶æè2“'i_CÝ¾Ñ—n°&\ÓÝKl®·}JÖæž$l®yo¯âÞ$“øài4ÛÉÏ)Þ
±¬¦/=MšSA0Gíës—ø_G»Õ‚—ø-òü‡u¹#ñI,
Ì¨;nˆ†`nVçÂ±A¾*Ì¸sh¶Mª1ñ£/m.©·_ ?œ±¡ò—ïŸÈ<ÆŸÏF²Ù®0ÌlùŠ~ˆ8Ü¥zÜvÓTšòE÷(Ç)»“EDUØS#Ï‹-ùº3±tvD6{cÒkí4]ôüêöÚG—Êh÷»PýGÀü_E¨Rÿù.h¿ªQýÇà÷úýWÞÒÆ“þ;ýÔºqHÍõj’0{ã„n0s	ýÎõÿ^ÿµŠO×f!Ç/ž¿b÷ÚºèêB|³.®ÖÅ«sñšZŒü[lù¡û/NKUøéºÔ¡¸TZaŽÆ¾&®9½´ú2Ò§´¥ÊÜVn¡‹µ,æ|dãìÁ1-5Æåsc¸ÆÜ%ÏYS£I	».fÐËÑ(ÏZÄòÌî	ÂžgÛc‹Éï=[ôØ§Üß§¨^wz³ó-/µâ©|ýø¢ûú·Œ`äé“‡——.¢PÏ
36áZùUþ¢Û-(ó‰€Ïº‰Å
XLv(Ó;î1*Û¼3ä'îØç)B.q*Ä2««±Œš®PXÇ)ºwS¯Ðú¸3Ï¨#7%ry:ŽosVOZöä??#¸úîÿªBîÿá©êïÂ÷Eú?÷þ‹þÃ@ÿ•Ïôn¬ã­½2èãvs" HqÝ4ÈùáÖ.Œ8^N{"³ß)ó}<µ^üCM/zÑ.RÏßft£¤)6¦ÖÜ#âÈÇ‡%Á*‡Íž1Ú„ßÜhÑ(è¸‚BÍO»Ö"ØÌ;öÊðEk7»bîžüïEÎ˜ÿ¨UÿWãgÕ_; ç?
ó•¡üõ_u¨’ÿó$†½¯øø¿rþ'ø`ÿK)¨ÿßý>D¾–„ZôÑ»ü†þo)x«ÿ+^÷¿x?ö¿šÓNSUG©©ï»]™íöòx?œïò_×Ÿžÿ:Òõ–ÿÚ}½÷U9óãÛÞW)5f·|TäGƒX 'ÒP&tiz2æòÉ'c™]^SŸ_“~¼VŒçr÷Ö¹F>Úº¾u®‘§Õµs~úòßÓå‘²ðìåÞl½/Âùu—Ë¹CœçÁ.Ol¥¿;Äî²ßíãÓV>ÜcG2W++4ºÍÆÂNÌÑ:´ÏÊB"aÐwN1H£hwcª}~Å&â|Ñtž¶¦ÃÐåüA„kÈë|ñ¼ÿU~už/´ç~ï\ÍBÍøØN:•ÅfŸTc¥}<ÄËhß`ìÙF‹EU÷cFu‹­Ž~Õj]þÂ©ÎxÝÝkþ„í‡-gvÚöb8
ÖrÇbD "µHÝ£Ëíã`0ä>–†$Ûj·¢…ØNT™á#u*v²ÅÍ°EÅP|(šTÆvÎæ¿þü6î‡Qý‡=Èÿ#Aÿ•*õŸ{}. *Ôÿß[ÿÕ‚ÿIò¿+BMø. *Ôÿß›ÿ¡þ‡úêÿï‹Zè?ôÁüôJA•ú¶¾V¨ÿ¿·þ«ÿä=ÿÃüW)¨ÿû.l{­
µ¨ÿéþoðÿ”‚7óÎWÿ·ûÓÿ­îØCo˜'B_°O†Ì&tùwþowX®ÿÛ/óÅÿ]POÞï«Áù˜÷{ñcÝ+ò;Þï«õy‡÷{¢£›÷»wó}ß®7÷ù¾M"ÙYmS8cJ›ÙÓ"ÝiHë~¨ÌM„£û¤}Ð.ÅŒ^ŠªÞ´ÝHR´ï$ÚÌ§y1õB?_·ŠÝÑ!ùœìó$U:q¢®;ã«íù¨ïûfûFø¾]O>§‰À7ã„E­†8n0ÌÎme^'iªXÙÌæÕéâÌkÈcß7ŸLÂÓ¢?iyØp6JÓ1†Ã	C.&=QÜÄ(å5Í<]Œ
Ñ.«îõ–k47¥kÎ„U8#—aÃ9¬º¶:ïM_Õ—Vs{R™Ùâû\ÔBÿAÿ¿2T©ÿvË® *Ôÿß[ÿÕ‚ÿ¡ÿ_jÂÿOÂ-@ù¨Eýùo•òß ÿòß ÿ­Úþ?ú¯"T©ÿá)ßeÛªÿê õÿ÷Öuà»óÿCþ{I¨ÿû4Ža!ê±L@¹>Gâx‡‡¤¹AD°T2lˆù$íG‘Ç¹—ß¡ÈåP† QšúwþU?º<êÀÿÿY>3ÿ“¦ÏiHŸM•¼ÓPœ"[Å ]ª·Öp†s%<´õ8ÞÐž.Þò?õUÔ3püÔ™ŽxCØŒØ¼éÄî±GbãbˆaÐ!ÑC“¸ÁZRžn›ýX‘w4¶ZÎŠ˜¬Ö›5³btRµÞ[ Òº“@þç{ñÕïÿ+Ï@ÿÑ ÿÊAôß¥Ú‡ùÿŠPÆû|þõð?ðÕücwý¨ÿKBÉü>ÿš¡,þÿ‡þüÿå üÿàÿÿÿ÷EôF=ðÿÃü)(ãü‡!ÿúêÿï­ÿêÀÿ8zçÿ§ø¿”Éÿ0á_?Ô¢þ¿óÿôÿËøÿÁÿþðÿCÿôßWÿàó¯/ þÿÞú¯üýÿêP2ÿƒÏ¿f¨Eýçÿ¿ÔÿÐÿ/àÿÿ?øÿ¿¯ÿÿ«ùßw›ÿóýOÒ(èÿ2PýO2÷÷? ÿKA	ïÊ¥}Òi–ÅP"bqüªø|úòÅ„aäy”‹¹¬Ë¢—ßñXŒÂ]£.¯`,G€»÷QÆó‹ÿïý¿Eþ/ŸéÿUÚtºna¡®PnûØ"GNž†K­q$ù•Šž/óæ‘ývòâÿýïm«k×
ùhÛ
ü¿ïEÎŒ!`þ³"”ÀÿpáWc”ñüß¼ÿ»Ÿÿ¡	Îÿ2 ó?0ÿó?0ÿS©þ{tÿCþ+_}þ?5|aì§¶(ãùàþŸ¡	¸ÿ/uàœz°ÿö–‚røŸñ(Ô£1Âõ˜ˆÅÈÿ°w-1Ž£y}fvv¶æ›éÙÆ½ó `—¦ØeÐdºã·ãF#­í8‰“Øy?iid;¶ãÄ±“Ø‰+jiFiAsA{Á‰=p…å {YsA8 7àNU*]]•®ê®êI²Ýß¯ÕÝÉ—Ï¯ÏöÿýÀUÖ$tL†IZgM”ÄQœ6M!	ÖT	F£uJGÅTÕ±t|YØú¿ÆþÏ0Pÿßž¥ý?I[&—i©hkŽ†±Ý·êZq¤ö&FöP£‹”dvðn›7–öÿóá*§£UÀUÂUÑ*Ðþÿ¤Ø	þ®©ÿíÿÁfø?ûÝUlŠÿ?mü/ó7ÿãaüï‹ÿ»ò¶Îþûm_6ÿ_N€™¿;ŠMÜÿ«ØÿIÚÿ7 ÿÌšþ°þ×F°1ú¿üpÚ yÂöé?¤ÿÛ¦ÿ8º¦þŒÿÙ¶Jÿê[¤ÿþoþcçêÿÂúoÂÖéÿñQïêãçquw›¢ÿùÿ(Š8Gÿ#výÀeþ¿ÆÂÿg	ýù®>¤î´hÆñÚkµêžkëòsïÿKYÏÜÿ†iëä•©>(;ú >;iUô¸>@à¤Ðé>@±¾åOTG¤ƒ‘ª–b‚ÍcY3ô•ÊÌ™¨šÞï¦Œ:«`~È‚~œÐ{íÌhºÒW»¢±5sN©ùœ>ô³ZK´cÊ¨À;=ïÏuó…ŸW¹0SZúùø£k•ra‹çKµ.bÂü4Wª¥øPMƒN÷ëš˜€Gç·j¹a"‘vƒš–Mˆ’ ÅÑ‚éßäh*=Iòh²Ç—y!:OªFM¿ÝÌ:ºM=êHmI™Õo½‡þBp&qˆÇ±€×Ä¾ê•³C¦u©§çn×íÑY¼ÆÍ«=SÌªé…’U˜æó€(½Ú÷u6Èwé)Ö˜Š¹:žíj¹LÛ*uj-²Œ-ý¹sî†üw®þ/ŒÿÚ¶.ÿé*”ý¶ˆ]ÿÖÅAùo3€ñ_0þÆÁø/hÿƒòß6í}c¶í¥x!±þŸuù	å¿MàYæÿ§Ñí¥´b:ËÇ;(HÆû¤ÚèñŠ[QòAJÁK­øí 4ZæÿUéŠ0£Fµê‡I2—Ÿ¸¤B,ŸkP`Ì*bj¢DÑ2x5Þ™)î|BäÇÃ¬ÒšNºVŽÏÎ¡ã›ÍC—Äaþß“b'ø?ŒÿØ¶ÊÿÍ!¶½ /8vÿ£0þckØ	úõ¿­aëôß·-öÜ ý‡ôëôŸ:çÿ…ôCØ!ú¿f,òec'ü¿èyû	ý¿ÁeþßdR8­ðÐÿ›5¼\¦pUÛM'êYÅªÊÍÚsUÿ{û÷,ë_-öoúÎÆþ%¦þ(ÅNgc²èæT¼›KHIUÓŒ—Í¶ËÃBE–Ô–‚zCT?¤`ê%°äLkùå®LÔ»q\Of:,Œ„ŠÞc%4_§Eý0i¹r‹O-Ï-œ¬ÎÆó­çkeÊ³JER²R™Ã©å˜“ÓèŽr– $Y·p¾6’ê–ÎžM–C.,s’ÕÈ9±.+¹&qÓdÐët4ífAgÄÔ}<ÖMùìÔU¦(«•‰§|v ¤+µl&00›â¦ªTìéñnèã†FÓ1Ílb%%ÔºîsïÆ½2vBþÃ(XÿcKØºü§v64 lPÿ±å¿ ÿ°ÿçÖ°KôŸ[|ü.Tÿ7	¨ÿ¿Øôÿ2ý_è-ôÿUþ_©•KRmP’'ù¼˜È|kÒ-ÏÏDæöø¡\òC +Ìi1ÌÖks±*GZØ^Î•ð”¯6Ú‘.L[U±!ó¥c[Á¡¬ÔðÔDÛ3ÐjP=µ©ô´¹X“yéxã®œ?Ý KÃÑÃÔœ«Ûäjr tOk°Ò¬y²™¬Š„œlÍ”ž8S’ý™âxÑ˜t<–\…õž˜?±\€«š.N,`aºH÷¸Öòôd±–êkgRJ_®û/>ƒÓºÿ<KÌ{À·©b0µT§˜/â­´_(õv²äºCÉÇcý†]ªÆ<ÕO’€/ç –m£huT’Šœ›°…^?ÞV8ºÒ=^÷_¨þà:ºÿBõéþ•h‡å’Ôådu’Ó›‰¢‘n×l¦Ñ¯Ö:C1[a¦YÀ¦ÔQ[3‡år•³9+Y%éLÚì[ÎÔÝYˆ¶‹õ³(†âU¡Dy‰ì¼ôÑóÆ}eì„ü‡­‰ÿ‚òßF°uùOW¡ò¿E@ýÿÅ–ÿv‚þ“çú@ÿÿ†°3ôöÙ
vBÿ?ßÿæÿl°ÿ7ìÿûÃþßÐÿå¿­ÈG­á 	`[€úÿ‹-ÿíý‡þÿ­a—è?ìºyì„þë¿m°þ¬ÿë¿ÁúoÛÕÿ‰óþØÿm#Øºü×7f~à¨ýoPÿ±å¿] ÿ¶¦ÿ'éÿ&°;ôŸdIFW	Æ4iUWÙ„jtTÃM
ÕhRÃ(ÜÄq4Á¦›¨Ê ¦Ié†ÆÐ›`ðMìYÏïóŒ] ÿ°þçöð,ëV™6S±I7¡å[í!3õ4:¯bŠŠõêåŠßl—Y³Ÿ2Z;©ÿ9‹Í¼&ÏM­˜>«â8´”á<>žX}Çé>%…Ý¡E¨ª2v²ô<aã±Þ¼VÌöaZœw™x;lŠ¦9æh/›Ñ^)hÂúŸOŠ+¼ÿFç)]uO-ÿá8Ã PþÛ®xÿ‹†1>J×»»0Ñ_rŒKí¿8sæþSÆ@ú¿	\fÿM/ò¿ôSýß”IÁ­+±Y'Î§#ÒÍØžØwJçì¿úüYÛÓU®ybÿÓì¬=4Pj‘–IrêI˜ˆ+]¬fºº"WõPéI¸\•ÐBUÂ‹±ÞÑz2=^[ä²]5•œä²Je3e=¶õ†a£Ô(jƒâ¢upåÊ™vfU¾.â¾*q|z’Èò%,Ý?¬Tåº—Ÿ2JÓnå=* “]Ð(W³|ÆÍ÷uÆ)×Ì–šãr)µS±mJŽXv{&J…‘|¹S,ÓmRœ¥­0×«Vù¼Ì‘Çù_Éãü¯Å½ÍXÉH$8ãÅõ8N^ô‹æIa©/9Nâã¶:ax‰gÁ¸œï‡¹Áh8¨º¤
cTHÑ²g©©ª™óV—udTF-Nk‚TH?W¢ Z#­Ú2È„:g©ïºí“”(£â6ja
¸%Y*G{%;ëx)Oª¢Ê,3©€f]ÎUÔž	$ËL;J­Ì]dÛ}q¤„]Ðÿ#f ýÿ[Âù?†Eï­†­™¨Î$4aFº¹©“ZBgIœ0Œ¢Õ	ÕU,Á¨¬†1ªÊª$I1w†c{ºík‡ØÐý¿Xþ‹ôúŒþa8å¿MàýÿÆS PT
óy>çÙqÖîkôÐ.pu´‚5%Ýpœ©“Jú¼œ+¹ødi(§‚_ª)å¡\ëÏSªÀÄæur 8^L3¬€¬÷k³R™šQ)Ç jõž¶-¡Ûpkž7©pWu.ž¬Mfùd¦Šƒ—»ž,Üx¼àÆ‹ÃÞ/Ånðÿ5õßaÿ`kü¢mûÒ!^Úþ¯ãÿ8äÿ›Àiþ_ãó’pšý?¦$ÍéŠ4*ŽÅT²¦VSYù°aMâ>fd­¡Z7€WHµSr_4ôI¹ÝœÔSe¶ëyœWb¹\¾?Ü`àrÅËûvxˆ²™¡kU%5ÉY}tšŸ=³m¯ÚóƒëÚŸä—¼ÿøyû?I‘Ðþ»|ràªãàÞÁêŽ|x0ð‡v'+Œ-L®£‘±çþÁ=wâ8¨¦i;ö‘³7šýj¸ÑïÎÀpƒŠ=ÁÙÑƒ{Ÿ,êüÛ®%u¢ïv0‹¦\W†ˆa¯ööÉÁÂa›¶®‹Ë¹À®}ß½®a;ÚÃ5-Û÷Ýëš¶ï»×µmßw¯kÜ¾ï^×º­ä5ÍÛÑU\Ó¾}ß½®û¾{]÷}÷º&îûî:÷}÷±FîûîÁ§Ÿ~úôôùáŽe¸†oûw5ÇÓ/Ö/¦ÿI gò?p‹DBHÿ7 p°›HAÿø/Ù?ýí­üõwÆKÿýŸu¡ŒüÃÿ|þ³ÿüüw¿ùàß?ÄÀgø>fà·ö^¾ùòþk{?þáÏ~òÕƒ7Ãô®j»vçƒï’4‘ :†Šª$ÑahÆÀH” ­C`¬AS4ªa$K‘:‹S•èD2>eª	ïÑ
×}ä½ó'_¾9úêOŸ}ûGŸýÅaXøœúÑƒÿ"€‚ï¡Èï¡È?¿Þ<×÷"r?øÈß½ƒ|ï€ËçòáOÈ¿üàmðê‚‹!¿ÿöþÝ_‰¸ò·/n!ÿr|mÉß|í27hiÁ-ŒÁªf2«º‰D-8Y6cP~¯òÉse0çÏ¼f[æõ“2˜¥õTUÔeÞ;É%©.òHÀú‰OžäŒ¼ª‰q•tpº&Æq:L?L…Ët˜C>º~ýð\;ŒSm3€xx”Ò³~â(* _Â1ºÅ'ý¾“æ¹ìŒtò£n<÷Å6„ÕQkèç°y t¥ZrèøŽp©B6âa™X_Ýy*¥L+Ø(œérŽ&R]U1åº¦vfz s‰#Ž‘ÖGæZiÀ§_¸“|™êñäZÈ-XÏœçÖ¢d•¬´8#Æ­ˆ“*7RGÐÎRa×#éiIjz³|Ëí›Ýáˆ|l?a6îÅZ/à[ªhÉ8d5Ùù=ŽYCRð;z²5Ïå'– ¥›Ž^£huÚ¨Ô‚2—vÜt¨ÑÕÂaÐç¤¡QAÉ”u¿¿ÀwzðÇ—¾M0¨ ¼xAü[àÕJ†Ã‘×ÿRtöŸ.}Q*‹îKFlÅvÄi³Š•Y¾7ÇhEi£NYpgçÙ¾¶óð	<”‹F°à=×a=à(3Óº2ëgË1=9ëI„™è à8£´}’QúÔìœðŸf×œé‰‹–ÓLvBòx>ÖÆ"°™v£ZÓ{3gš’<¶‘Áû­ƒû¸ÜÌrö vC¢ÉTM%ÛåÐé°ÅæÃ½aè©&U¢/g?à„ÿ<ûaÚgÆŽ%Q°5Q™Î›ÜwÈLAåzóÓ™ŽD‡D·4:—û»b?y.3%Ù&bŠ¥l@R|¾–Sn«a±öŒ"‚l£ú‚Ä5ó7M:J¦bº«Ût­]+Œõ"è fR5û¦)¦	z ^ð–í¿vdÅðâ`ù	ùòK{/#ï"{ÈkÑÿ¯ì½´ÿòúJú[m€‚¯•µ©@O±EclO¾ÅËÿ÷¿ÞºªëŽ06Ž,)EÏ±õò>òæÞW½“sß7¾œ/‡ÚÇ—{zÜ¿¼ºnÙ‹ÎåUää¥Õ	<n3äOÞ]œíÑòýw‘ÿ …Up?òÓoìÿùR|þá-ä·?ºµú}1øW—’2XH’ƒ…ä”çÒ—v_€Ýžëîçdâ¿¹ô€I`EX‘äBÑ—x(—þò­HÜ?%—¾…¼yZt[m„¯äÆ'ß†x(2?ñF+øWÀ­¥,Z6ü`lëGÙ£ÈÞÉÄý_7Ö\Ãõ'~u64›ÈkàUßs¼Õ”ð:¯z·bÏämä=póÁƒØ{Ü^ÍùxóhNÕÞ$@ÞB^¯àþê"> _ç>ŒºêØ#Y<’ãoDRøë«e\Í=xxÁ«9ËÓsNVÿ‚ýœ,ö{È[Ñpòýæ+çÖé×ÁÍŒêwm×âË‹vÔ,D{°$™«ë¼~ñè:’j .7¨ã‰LÆGK·÷¾¾š.›Ë›Ãu:cÃ÷¡}ðÞšLí{J¡ÕE¶²*{à¥ã?×ÁSûÿ:ÑfŒï,¿ßœKqIüÅàÄÙü?‚€ùßÁâŽGïÞí÷ñ÷X<¶nø÷ÀíÛºz×[Ø#d ¾}Û¨–qïv7¢ÈcÇèXÑC±|dtõÞ·¹²¹ƒÝEï’G“wj=wr¼õíÛwn§8¾,	ÜÇ™‚,~7=¾vwËgrÍ†±\Ë‹O
íbÍÉ‚_»h«óLIù'8øÃRîUœòâåÄÖÓGÅñŽj­áªªQ‹*EeÒ´©ë†‰uSU\#¢¿,ÞÑLÍdi•$†ŠÓêÇ~-ØÐûÿö®½9q#‰ÿÏ§˜S\yl-ëµ¤#­ÍÅk\€7•JåÈ b!)#	¯Ïå|ötÏHdÉàõ®“»›v•ÁšžWO?~=#É<
—B×À‡·Ð‘·4q¦0§žÝ&áŒT-òM~<#"U¸"ò½t\F¶žEÁ‚d“m^³Û§5Ù8¤Ó½7t:Ö[õ}›Ú]Ö²êôRº·×:dûõƒ½Ö¤S»¾ÛØ§MäÁ!kí³Ý£CªS"þáh[ünHÕþFHcá»ñœ­ˆ«–{ÓEÀò¯¹ÈÏæ¬··M²^Dñ	Þ„Õ.29\Ê¢€\X¿€qƒÅ&5¶3ÛÁÐ0‡ ÕÇæ™9ìžNNÇ§æó´c³i|UÎÖÍ³®aÍÑ¨S¯‰ŸRnüõGïÍñÉÀè †lb-6/)æècÉ+Lª×=¸Ú7:Kìº‘Ûè_o“¿‹Fn|~Àlb;¼Mt?ˆô+? ÑL¹¥_¶‹§B—®ÕºÑ&í:b5ØŠ[ªöC5MÅµÆö™ßõó°×¼„ w´³zIäÉë{1ï•ÇJÛé{o04QÉûgÇ“sÓæ]”÷Nºý³ÞÀXrJ›0Ì£‹ãuÖï'·úgãNì9Ûº®Ïü0Ò”ë<ölUWõSÔÄÎ' ‘Lx7µ¶i‚v4ŒÍô~€ª'ƒÑ¸78{×?žœ™ãÃÞÃì:©MlvIc7*ètÍtÄ¹G\•­ŸwÇ'mœËrLãêŽÆëÊßFwÜ=êŽÌNÏ­™qôopÑ;1Ž’9%¥²°º=m¿9<h}VÅ‰Ï·YGñJ5‘ž¸gªsIÝ•˜pc}‘à&^i–u¦Díuz¾Ýoù%Ô‹•­Øòsëü‰ý"$‹ÝŠ(­Û,`žN åfâ,‹”X–¨:£T;Š£uÂ÷¸»I›È{œÜŠ£þ-•°ÀG“‹á)tE Nbuq¡E%}ÎæS´MõÓ2âmó?¡ÄïDI-œ=-ÇØðþŸÆÞn#ÿþLUþ÷ôÕ?ô©ãéSÎ*È˜ˆø¹txÆ¹Ï_“€;^D¨ë¦Þ-¬A¦.- ŽÁ"fA1·f~‹9« ®w~ÑNHuþ+¶|Ìé”D3F¬˜sÐk¸}~[Að¤í|K,›àˆŠÚÎxø“Éhp1ì™?×¹×ÈwùúkÜØðZ­Èž„m‘õ	R½Ä í{í±Ý¨vã}†fâ r	œè^úœœ,‘–C"_F`s<‹Bóþ¥”rHnfÌ#à±ñ)	âÒj¥â~Mœ0ŒaÑk¤i&D·áx2î¿7ãÎ[—rìÉ‹Ñ|_aÖÌ';wE¼÷•Ðe,(-…Ñ‰»˜\/¹çW‘s†10«xÉ˜—ðK6QõóÄ§˜v¦"Mk¸·€ò	wâö_¾ã•	$¾2‰ÚÚ,ª c[“,¦ÈMÏ…9m+Áü†Ã…D47õ$/yaûßÖÿGŒr´”O	›ü£‘ÿW³ÙTÏ¾ýüí€Œfq$\¸hÛÖ!µP8b,	oÃˆ;`a£åœúã1 Àã_; ÌVÌ"ÊÀx9›ûéX„Ãx±ÊW|9ùC¯eã×øåê5„ÆeÕ€û¸;’hÒÂ:3gâù8È2ôW+‹äÃÂÔ$ñ†½†ÀüÍçÙùv­ ‡xEª¿‡ýäÇ<©BšsC,—QOÆü·ÑÖç?"š§ÙœKÝÛ2lðÿ»õüóÿðÿÿ·òÿ_žžëÿ¿°Šç×VÄž÷}–Ü½’ûÿd¥ x‚¯ÙíêŽðuä•ù5—Tƒ²V+VPÈ§ã_•VÂH\L3üG–S#ÉÔJz/uþÈÛ·Ä¼#ßo)µeIí·Ð÷*wbŸA‹ òjm¢	&íµ¼˜nìBÁÏé†ÍÑbîjx¯x`­mI ¸×È½`ý%iÃ¢P;©„íç·1ÄÁÔk’í‰JòÙt¬ü SËC¬û¤u±µ:<r·Þg¿Çû/†§ZÉˆÓÙfUØVí‘
M-ã_ŸêŠaÝ;<å¼/ÖˆTÄI &»ž¤_ô,ÏžÊOVLÞÖ‚%Íz]«ÜW@dú§­¦ ©ïNuŒÌhH¦Œy‰FÚV*H\Zì|¥g1M…ùÿÚ6þ#~u}jü¯¾ßÊ?ÿé_CÅÿ— ççd_1kzÁ¬ï<†ÁÀ@HD¯d.E1³+ò\SÜe9L¶ù`ímN7ðçnwÙÄm1oñ”
Egó›ú(8lx|ýì? Ö5ŠaÁgÑ±÷5vwsø¿±×ÜWÿÿóEaR³*ƒ Zr“²àÍ	•4›É‘0’ŒdÜÈöºKáÂèŠ¹~€]º°à æˆR’Žñ-Áâ}>$â1—8ƒr=âÉuÐzåD)*Z™! ·’ƒÛ‘E¾ï†5¬_I@¥Fãhæs1±%Çç:`Ô¡è»f3cÕÝZ]¼^‚Rm¥ãt”bËWlÇ¤WBßÅa'D J-	ÄËé *±¥ÌñÌ€LcÇµ«bnÁ2P™»ŠŠÝ€T«ø!0`-âtá„:^ ƒ_ÎÆç¦Ì³¶Ò9rbKÿnÖkY†€W«WÿqdQ£ÖJÄ"$%‡¹’´Nï
ý‚ý«­âÿ‡
üÿs ^!mÂø²Çuÿ¿ß|£Þÿó"´ŠÿB?æ#Ÿ€Éô	*Þº4S¶«H‘"EŠ)R¤H‘"EŠ)R¤H‘"EŠ)R¤H‘"EŠ)R¤HÑ‹ÑŸÍ¸- ¨ 