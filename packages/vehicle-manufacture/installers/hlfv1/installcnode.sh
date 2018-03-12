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
� ��Z �=KoIz��L&f�� 	r�Se��|��,Ëp$ʣ�-)�dc`x�bw��q���d��%� �%�qs�1���  H�k����ztW5����d3d6����ޯ*җl���S?P;NB���*�Z}���ū���m|��j�;>�՚;k�fc���۬7`\}��h��ڝ���D1	Y��I����=�?�:��w>)��f���?���������ܛP�-2��(�ߗ�?t}��ߗ�`<	����kV}Ǫ��7�>3�s9_�ʛ�4����q0Ѫoo5j��Z�V����0�a���X�z.�ɠɫ�1�	�Gq<�����t�B�9CZC7%}��
뭈�'^�TT�tF��W廋KY��0�:��I̜����Fp��g�I���h��:n8!V�q��|�Q�#��;d �lmEA���&0'�q�%٢�"�m 2�A̢��'c&>�\?��m��"� �X������-�/���۲G�~�N��4'�Q������P?v�2dvF@�M�S��0A":�%[1��c�9���� r� �"sc`���$�4�K)�u��9j�˦��ѽT��5�§���Ԫ^m�i��ǯ�u�A6G��A�Fl�6��vy�&�w�o�ҶG�E�nZ->$]�:c��,^{d{���K��Y����n�q�9��l���Ɏ��4����ö���T�2B���p2��01���q�����`,�mX�]s���8�!�)
m��Fu�&n�����aV��{=����nI�}��+�0'4F�1��ߡ����~���v&�
��� (���ϝ0D���צg���_���bm����n�}��c���D9�g��=�U*�����H9\��"�L�Tۈ�`L�O\ߍ]��k�Đ�UV3� �H p1�C_O��<��"m�:L<
jB �La�$.]V��d8J!c�F^�
�lE)���'�@<+u}1��D�Rq�}rFCp�<GTzsk��FcQ�
�7bV;��/�9E�a�d�||R?��@+:���ȋ����4N"��cq29d�@��\2?6g�[E��Nt�w:�T1�m�R	�φ*pc2K�\P��~�z�!�k7d�!���#%���3&FI��ݠ>�bs�H8�gWD�"Ac���v�C�.�O TNSzȯS�� 4�{D/Q�@s�P0h,�̉�� �EA�G�a���F@��+�D�B�k�ЍX�#'�ĳ��$��#;�hr����C&���P�|�f-� D�5���i��s�{_u/�v_�v_?k�\��/����6+BxK#k��q��)+xi�,�$s��/,!��N�����^���	���N�� i��t����2#���r�M	Š#}�N	چ�[ф�������Ӭqi�
ƍc����8�u�����Aci/� �)\,���+��4��� ���Vl6sk����;���*H`��A����|�{�_pT�$�O<:��N�^�CLC�<66p���i�˒3Tp嚹G�g��߼)�/R�3����I9���̒��JVS ��5�X�����<2d�J��(d3b�h!bT*	c��>�|B k����������'�],]��
�:��7�C7�'t�䭎d��x�)o��̱�s�涸)'
ˁg}5��ͩ�b☾e8-d�ٟ;_��}Ώ��s������zd����r�r�S��2<�t�RT�%�1�`�H��F���Y���ׁ�$E�R���0t�w�+��?������W���>Wc�P��g�dC���[��űV���5����.��o�jp�>F5g����ʕѶ��/H�n-n��3�4E�7P�Im�j��+���aJc��瑜E�zi�#.�
	���%�W$�"����%gHG7U����,R� ��";�ذ�%ڷ�^�{�j�H�McE�FLFpH�W	Җ%�q1օ�@��"�ƀ�3X��"�r�M�K�< 9d����>���{�>�d����&�݋�{R+3	�mR,/�4�A��ϴ�Jkb�!��+,V���$�!i=�T����$��,�|��#Rz,VwgG���P5L����T�_!�ʳ��(�9�<�����7Y��;� ��ߋ����K�/U�B6���x�	��B���s	�#ݤٽޅ��4��f>�̍	��Q]�P�X� �L�]H�䍪&�]��av�K5�Ң:�Vg7 <w��)\�:
���E��y�+^��t��j]oc�к^j�DI��'��:���
9�~d
�+1Y2b�S�][��^�g�	n��~���v�d�)�!�dcc�U�D�u_�� I�o�����⫔�amlk_D��[�	d�Q.������n��QY^$�uz=R2�GM�qѶ�A!���Zg��s�z�T:$0�
�OSXԛf�p�|t�B1���t�+�3��!��Y�YX�m(yj��]�#L9��t;�<�`?z1�lC6�y���TQ�+��5��{�Qg�H8��@n�A��Ҹ���|H�k�*
��v�*�oh�}ݻф���|�L��+�|@A��!�t��Ceq_�X��U��<L5"��0�R]6�bH��	#D!a.�J�<ͳD���Q���4�boc{:�r��-��6��/J�-0�~��kk��s<�`�%Y$'wl��ӎ#@vŵQ���,9x�B=�1��{tO�K�[k�L�����*�����NЄ��[�v��Ùv�;�X=�$?�!��HĐ�����1��o>��2�A�˒�WM�V`�GKvf�E�W.����e�ӛ\�n���u�����w7��Gfלld���A���s
Y��n�5�<�/$W�'�9��}l���&g�_�1�pA�\deqH)�p#��F*}{���)��oN����3~p�Gn�#���ɹڮ��|Z 8�N�ܹ���\Ls�n�����C��;K�)�0���!�kF�W���zg["��)�s��)6��yF-"-]-�"@��8i#��76�2$�s�c�Ǽ�b�#�F�)b�ō#>e~6��U�<+�F1[���YoP��G�ojx&�|�{г�E~�[�(���㻹���!��2;�	��q�WQ
B�)�q�裀~���r*�ʋ�[F��ͪU?�����nT5=�����翷���B��YvT7Jd�<�Y!���<�%N�'��8�OV��〲|T~�AL�<�wb�T!o)ˮ.n�c{�o���G�����0��0�>�#&L�j'A$4��8;�����ՕE9�+�Uy47�>=>��:x�YN��=�);�g�S��H=�u:�Ð�J�����m�(�W4d��n?�~)�p#S`'"L�����v︷�@^�uzqN^������q�GN����������>���7����M�\����MB� ��"'���z�c�(�>���@�?Lp�v���x��h����ܱ�ݐ�p�j����&��,v�R��tv�a����S*���J`�ᆸ��+#X�Zp? ��oǥu���6���/��C�!��\ڶ�{���5X�~)E�:TQ�怢���&LuW���|��{�!p�v�D�L(����q0(Ji|O�1�US��8�)��w��?��*~������E\P��T��2���P�guJ���矸y#O&&{՞�^���*e�@�}[2��$��<��G)h�~@���ٲ�5V+���:I�\�w��Nra�����K�΋����������AC��v�\<m��G�gQi��Ȝ$/�š��vHEZX�}v&�Ch�ڇ0uY�>ǣ�g�t��	R�М������:�G�ota��_���'���\����_�������gY�F?f?f7�6���%G'B]����+f;Ob�_>�s0y
��
��k��d�#S���᚟��A��ɀ�s���;ND�	13
 ����z%Z���_R ���ߦ�1�
�H|XG����1�̣��H(x�X�|v�U�g
m�T*�D�ے���OHQ� 3̧�<��C*"5�̌�E�z2r'���b<�g 8(��0������1���.���$OH���]]ynI�<��q��	���ǴU��~Ua=U�u�� k�{��Т�#�b�.�`p��G�Wy�a�K$V�[&������Q��x�>�^�C��S��)�LpP�Zeh���Z��I��GN�m.����!D�|Vr739εl����p>�j,�A3 ׵;�C2���4vI�͝�%PP���TQ��J��X��/IE�@+�� ��m�w@
X�k1�z-Tɦ+�����/<z�d�o�W�S/O�^��,�!t��6�Z�f����ؖ������}���&)�����a�>ь��c��-���=���3�&�ɝ���"{M����`%���%`S������v,OTs���"�B�Y���&�1�<�sE*j$C��hA�#�\�S�^�[���a� 7�F\0�R͍�Z�]�]�,o~�V�b�c�fh��u!��<�(J�үņ��$��NqoYF�bB2vV�K��YzRuEqb�D���b�\CU��يG�=���-� o_)!IK�k����E�uVN<R��E�P飕;Lx,|Y��}g��_Qߧ#���1��0���x���1�1�mq���_ xq�w�>�}M]|�x��?e�Ǧm߯�J)0���)�/��E�h�Qr��e�o!fh4�O�&U�_f���|r�$��p�e.R���%ǃ��Fk��A���5�t�U�,/�8�L�GΒp�	��zh�I24̌�6������w��Nc�a7�}�W����B\���b�]�~���ҁ�3���<K@%oN�^�Uo�X�ַisצ@4YF���J��)���FI4�$�3Et��U���_�1����]}1���z��8{����m�l�@g2��M��)ݮ�;�6�mך+ �s�Kl�|T�:�8����6������5;wXk�^������JR�m�9���~�vW@�IȘ�Q��؏�P��C`�V0�~�(v����; ���Yk9�m���Wg��x ~��^����3,pz��JI�;��Ns�X�;5��B�>�As0h6��=p�{�ݽ��x��vn������?��|2YP�; �a����4�W�[A8��7���;��%����^�	�Xxeml�����:۫��r~�M:R��%��ak��Zͽm��n��X!����z��Ao ��y����%ы�:4-&�C+SQr����h��gxW�EN��v�B��}���o�� �<B�*E\Xc:�.�Ǔ�X��K�%rzVWj��N���8Y"H�Qfn]ce�Al�+��y��19����U�%z��Y��R�/��+�:uʀ'xU��+�m��<���)��y�ح�7(�>i��.'0����ö��� ���u�n��kgM紳��E�0�/L�6��23#x[7��w�f�uߖ#m��4S�s((�D�=� ��gwR��/�<�_����X!.�Qw%|WڧY�&��]�u>��;zL^�z����h_���!�-�l8)�ǽ���m�k����#":
B�ۡ�R1��|�W����� ��G3�Q#g�ʡv��p��GUC7��y���1�~Y��W��*�AB��lKJ#�@�L,�[��,���[woVYM�v��׏��9�E
V�W��Qi>�L��$n�����,)����л�W��g_���6�W�͗�����_5�^������i�o�g��$3��O���?����j���I����_���/Z�c���y�����U�˝�;����}���?Y[�=#�_�������������5���j���nmw�Vol�v~��?�����ev�Q�_��v��#���\,��\�R���1I�Xb�H�E����H�@Ȏ��Q�ŀ�؅w"iRy����5������o�{f?� H��/1�������t����tW�ZM����UʘAd9��.�׻�����I�/�U97r�^YՊ%^���"���р�<M�	J`& ��퉜!t���~��C�6��\/�U�j�X�w�iZ����t%�1�
[Z��
[�]j�v�'��U��PꚖ[S.�z�;7L�px����/V���w5�=>����B�[-��^�X�ӓ!T�ӕo���n������l6_ܸK0�;&Ǩ�Kn ��$��RYt2�����+��<_V�n٨E;���K���y}�1��[�Pb�u�~(�����E&�d��{�����g����c`-�ƍ29Rb}�y�=�FcL��}
�4&(��E����\�Z4��1]/tky���&�7��6�i���w��B(�>���M�M�8���l�������#�Ȣ�{��Փ#���ˁ�cS��)�Ύ��9R֠�٣�fo����{�$Ah�掣�sDrb�i�LHW��	f�!G������ [	~�]W�����Ҳ��K�b�jz/{5^�U��rz��/��ƌ�}�ّ)v�f:f�l�CO�!f���]����o�����{���Y��0Y8XS���+Qo�%%��R~�o�M��?�r�^�T)�Z.��(c�}Ö-��� ��$}}�!�	�sO࿧W�����XZ��?No��<~�t<�@�%8`�׎�ܕ����_�.��-/i� .A
�@�U���)@:/?����e�X�ˏ�|#j����6�K�#
'88��	� 'nC�H[���\`���.ɑ#?�2�&Ԡ ����=����تL捨#���\Q��;&����L%_7%o��O��?�A�^�Ĩ�?�i�=��]������48�p}��I8r:���P�?�һ�4
�F���\��uU���q¯��%�g�Ԓ��Q5]V*)4I���(�w�~�z#��:H��T��r���=K�L�z�^ɟ���@���]I�Q�mr���!������;ͭFb��D��I�|Cc�TM3V�,�T�E^P���^��_bd��xw|:���|�<D�sڛ�rE�{��TX󩣔�������dQ�&t�IE���~k�m�z}�EZ������g��׻�id{�]V���~�m�"�R)�Z��#��e,W��Q�U~�J��I��_����Sk�>�6�m����G�A�_�9��\N������b���s���]�Z���Y&��׈_�`��1��SjdgmyG�[���A�؀k"���[Yͼ�dZ���J�X��\��q5c��!S�޷��¾�`��Pb�X�ƙ͔���˅f��Q�2�5[�]ǥT�-�9�7��|�q=�z~f�m���u�u�� �l۝ w�Q�Q�VC՞s PL!��B�e�8���ծ��D�#�
 ;x��,D>�uq'�pY�+���!��IFwH����FW	U��e��(&2�#B^Y<�R<^2�ѥ��Ѐ��l��\��vl��Z�{,R�ɴ
Jk�u�3���/3�����)�2�X!�d_2"6W$�9kJ�+ؘ����.1	&�p��x�<$h+��&��L�˖l`���	c]X��}n�%[

�<��@�A9~az�=wu#��33?�zx~�'e�GN2���|���9-����Z�T(>����D�y�NYZaF���"��0�N�_���9�clU������Z?!����.�?��ȿ��jq.���)��>�/���>���e?���x�i ̓���K���\�A���}��,n7� $�h��Sw��.�9�o^`5 8Q p��x�u>�I���������*�)�?����(��>��n{F����W�c{ "�Yd�:zW8iƎ� @�9��|�"�h�l������j+��7ҳӖ�����e@����xu������:���>h��Mb^��'d���ȟ8�����t����ם+���m\"l(�[z����$lB��bp�zl��[�C�!��l��)�Yݕ�1��l��v�R�?-t��uj6ֱbi�k%��r�~�Nu!NT�$���s�˿;�ekǏ��  �;<dK�o�[r8;>f��ol&�u�g{�{y<�rGa_�B^5�a]�ɜ�&	+ ��qRA�tו$[@%.
��3�3��?�f���S)T���<��~��L�����rl���1j`���˕���R|8�/���?m�����i�Y*;Q0k+<C�wt��]N�Jj�1��Q��}��A��֓"�	���۸���JL���?���Z#h����������~�k��G�
��R)y�+_*?���I��j�:O����1������1e�4�uX��\�f9:{��g]t��@@t�<���z��fL�Cv��j/Q�C�`�?8{t��>�DGن�陇~$�K��������>�i�jl�o��ܺ8<���S/��������Y�O>�" ���Gh�\[�?bWx��W�Ť�/�Ѓ�����T�$�5�㢠0��{K�З:Sg�;̞�3����u�L՗I����,����l�e�X�~�y+�2��*����w��H9i.��� ����3k�xK��ls���z���m-{L|��\6û�(���@�B�[
�I�"\��L��;.?�tN��xwm��pytȖY��c9����̣G⼠��=zt��*�|������������Yi�{�=[�
➙}OT�?@����U��B!K4����m�;��<�G2,�^x�+��$;͖�E|�#�.1�/]����#N#���;�l��ڇ^�
�zՌ���6�VęQ�X%i!�����_�2�\��c�{��A������f::,�up�7B���٬��L?˲;*[~����O�ʪt`ODh="��7 )?2-6 �k\��$���T]����!���ƹ	=�LlCD[y��9E����tZZI�d�G��0@��L�u��~b@�3^���QF�pJ���H<q`(��)k�ﰯ�6w@�I�q(�FFp�����k������4����:��c�r9�Mv�hjN��u �����7�u���-`�}��oC�	PU�1Y/h{:�2�x�nFI�[=�K(���R�� /���k�S��u�*�R{j�0J���S�xx%NC�A��iBɦ��tDP�����@�F�����l��0�e'��`��$Θ����M:�y�����5��3p���w0�$�7�ޙ������>�L"����a�"����WN��Q__�Sڤ^ɕ"olz0��k6�%G�����Y�ͤv��S�<S�-1�t1����I-x��I<�j �
�Q���f�q��Cʒ�p.G�-cʬ#u��l��lf�ww�̲gS���1d)x�V��n�W��~ΨT�j�Z�}�ح�b��Z�\��9�P��V�赮V���^,�*'���V�ݹ�1��BY����0��|�M�&����6����;�ם�uo8Z��g4]�h��k�tjA���b��Q-�fG��R�� 4��	$0��o�bT�*�Ή�vؖP���,m@,�X߀0f��E=�%F2KP�E.b%l�+��8�{N�[7W�{@��3Ǒ̓��
�(%z��Չ���1��&�i��gE���S<�;��*p���M�t7�Fp���"����~����5��۸��>k���xn>��L�ԇ�ym� �����U����bA{���ǳZst�c��|�rF*�X߹�͉/zjf��������0�n]&���؋����Д}a�������BߴLO�b�/�����Ok�=��2J|�0�.p�'��Y��x=�c��P7�:�������F��̶4��]�%,`��1���$B��$t垻l���Ʋ��G���3���ks1.}L�O�;e�S-ƹ�U�]���m����8uyI�[zw �!����4LD$�Bh�R��O&�yz�_����K�J���sSȌ�~�5!���C��c[�f����u6F��]b�.9�q��܆E���-&$��L�i:���:����?�SXd����ʀ8�j��C����9�������o7��6�c�(�o 0�`ݭ=���K$�>xkbt�8�z�bW>�������D��'O&ʕ@dp�.�kC��a���t��ryB���b$!���&����;>�T#�69�}ۆw�Z�A\2�����DG��+X�-��u���x���v~��G���.�IE��;3��tw�ŗ���/`���.M�"{lT�h(C��R�Ю����0{2K�g���H��2�NK����¿�[.����SD�*�-{lyY�g��1L~��\"��bH3![�J�k���R���/����*��n�?v��&�bS�De��U5&�{6Hv�)��P�H���1��1� E�+�~�9��ޙ�'U�e��맧���w���!�q�@����0�]�Z��y�PiR΂;�NL�11lu�sGҍd��R�"�n-��9���&�d%$�ܝ8�v)��]��4��8�V�~s�	��z�Gv��G~�;���9��X��«�zs֘s���Rej�_*?���'�?�fN2ǟ}���?������3��_=�n�(�j���X���~Ѩ�j�~��/�+:/j�X.ֺ�B�Ћ�R��u+�R�[-�����>�$/l.�C�/6G8�u��Y�,�h�/���Lf���j�v�o2�7|��|���O�@����>	�(J��$r���/��g�����tY��2�=�fu܅�[�K(�(x-��x�!RF���|%���?�ȋ���f�{vwlz ��uژ'�E��<�W�<������S���,��F���n�)��L���η'��΋�����Qλ@pYy�.ؕ���o�X����|`o�ܜ?����j?\Qn�����E#�sNU����f	}��~�'����_ɵ\��\-�Z�\�:����瞞����A�x��Ϙ�@(�ʲm���t�3���������#��Aa��7��%P���Za���}�?E�϶��m�K���tl��Kߪg��>|��ӧu����-VUn�@�I�.#:~ni_Cc%Qeښ�9�ŠU��M(�z
��v�b0�4��L@����@��q<�D=�¡ ��Gw�L�纤�}
������Ҁ+z'rd>�*�VO������}�-�{Ђ�4�u��CE��X�ü�A�Y�,�:v$<���7��=_���<�V�oņ��'L�F�}�"�L�O]�0: ���[���!O^c��zJN�0�ޙ�m��Nl���@�TeIA�Hň�O�����BQ�����mRM�.ԣw�����@���x' &@���7;�<r�-q�-�%R��}F�<L�2�^��[�p��rLS*�m�����F;��G9��_>x �nf�q��ڤGXק;��3��mǄ�]�~��^�}�t��g?PQ�!��c������sDW-Ɩ���>У+}Ӵ{�C�a��|�A�\�0Z��/#K��Q8���&v�,�pb�i�}$�G~�n�ilu��{�1��s��g��H����K�g��[�H#�'`q����G2> �vhp��l#,�@�S��(�k�9v��Gw�8J����.����N7b3j�� ŵ�B>}�����lB��EDۛ���]�G$!�R΢�!s���/�|�!zyI��k��\7�k��wm(��b]�CP y7������E�����P�D �$�X@���#6��lWԍ�̇��9� ���/�Ű'�_Hh�&D.��f�<���}~�������v��p���~KT��玩�[��15Tq�	hY6\����Q�Zd}��v�Q����c��k0�<*���)Ը�j"�/[��(`T���ڢZH���!AJZ���y�rR���ܱ��� �Yj�:�a]��f /"��$Bϼv9k��䰲l/n��m%Դ����*U��r��ޕt)���7�W��M\��o��=4"("L�DTTTT�_�l"*����g2#C��>��9�S|���"�^�bv�_���+�Is�bP���=�
�;�����_C�/��e��o|��99~�|��U��m��l�[���3����k��������ߔ�����m���~���?������O�8�U�_��&��?A`4\�*�g���z�:����;��g��Z�?�Q���h��?z��~������_��o=�_�
���
ֺ/�)�X���:�����	��_��+���������A��������O=������Kh�	����k��y��h��_��h�;����*�����B�������Q^�U�kC=��
���%���
�� �XN@�� QM����v�z86�ő���$�Y��LS�ͼ@�G�)KEw䔒�_^`�$�f�<p�c��6�-�:o��O�����*�g�s�E06a)�:ݟ<�͐��!����>�O���8��4�y�v8��D>���K��'��S�'����N�¤�\������1�zP��'�]>1F<�l�ٺ����T�؈�{��+���3���=� R�ٞK&ֺ;W�&�n��r�(�>���&L�˽�N�Ո�\�e�����;i!��e�Z.P�����H4 ���K7v�n�ǔ���P�6a�*�L�p��U%�D�P;br/qi��IW��D[�P�{n;%r�8�{	�!K��ہ��rV bry�: ����e}7y�ӓ�iޖNr�N�/t��Y����/�,��\o�b�<���� Я'_��f�P�x �v�bC>�x1d�r���|�JT�E�q��s�t�\��ն�P'9�� ]2UaN���D}vƱp<�9;Q�A�8BV��ɟ�%�R_s^��[s� S�I�.��	�,�(c��Dڞ�7�5���}#$C|�����94C���_�*��P�ՅF�?�x���������U�����qlc�/J�6]Z��,���O�~��K�Nq;A�N�u߫FD�"Q:�h�oH=?�_4"�*ǳi9�kԒ��8�x��c��3�k;��<vԌs<��<��q̷:wU��8�[�r��;�6EL)�6�z-5���{�y�E$�:�d�s�������d� �ķK���D����L?Ӗ 8Α�c9����T�X�1�.���-
!��z��'U�.�j�ʑ��r�:c+�J����Xt֞�p�3E�,F��
�=ť��x,�}m4����2A�b0M�Saud����f�?���M�/��4>�}7>��!h�A�����3��2C�M�^����D:�����q������m+���U�f2��:��}����ٷz�XP�Iiɗgv��ii�,` �q��K�l�����v3u2_Ds:���q�j��SGݶ���;K.g��$��`���>�o�q��z���`&QƧ�����C#���Q������M��Q��Q�����M��O����!�������4��*�,�c�i�7�7D�$NC�_Mx+�+_��"�5�k��_���y���s6f晔.ͯ#pETJ=D�=�;Ӆ�H?I%��A��Rc��UHt�+�:���lqtyl��H��<|Yz8{�m0���ْ̝�R:���,�?�!���st[�[==�Pf���Qa,T\�U�o��{=��C_�!����e#����Bٟ��Eᚮ�\
<�R�>�o�W�����v�MLNOC[e�#c���.�=-�ײ�����YZ��4�u��p>�t�g�M!�ƐQs}2�h���rRh��{: e���!�¼����@3��_�����*�!;���j�Y�H��*th}�w)���cJ_t�TS sͤAJ����$��r���o1�J�õ�#�(Lډ�)��VF�<�:��	$��9�0D�#]��,�s��~ߜ��A#��~��(����
4A�ׇ��@��c�F�?����+A��: *��?6�C����������'�_��g%h���h��h�l�����B��M��(x�-�wF�
{R�MA��
�e����?����n؟����/��S��)���ﲖ��H���o�Z���L����+��~_K����.
9��B�ӏ�}��}#��c�ǋl��-�Ժg~5�mg�^;�|j_�[o�kX�7f�#n��2ރN�k���JCdVv:�q�m�c,[}9��o�}��}#�S�-��ɥD�����`�B�.U�2�>��8;��u:�m��?�}�ݢ�t{��D�#'�]Rek�s�]+ِB>�D��z�DP��2r(:8�Cgoy͂�&���i��4u�bNuv�ۿ�Ӡ���kC��~�C@M�����������ۏ�Pa���o�����`�7��������O�*�����|��bh�Wh�l���'�'�?��_	��FA��Nшa	���\<�Ȑ�8'b�hv�A�Q��L��\@���{}�[4��a����+���Z�z�����<i��:�Ʊ!���q�㨴4s�^�Z�����amt'-;������Y+����ٴ�3�YƔ3Rpy�3w�d����1D�-:�sOTl4^ż>�t���V4a�Ǩ'�_��W�
���l0�X���H����O?����?+BE�[|4��!����8�C�_����I������
�� ����?`������B���ڇ�jBE���4������	��c$���P1��➆�	����$�T������?`������l��P@��c�&�?��ׇ����ha�?�� �����������j��O���������?
���XT��?b�����@������"T���4�a��,�L�	��d�\4Mr1��4A8Aq�	��\L21�A{����O��4��+�������CZ���V3��j�N�Q�3c;"K���̤��CKǛD��Ò\��Z�}��U�c����������؍�(.����=�h8���)m�qp�����;�������h���>�������j���o*����7��&��_`�����0����oO�?p�k%�`��%|�@3Q���������������/��+Ae�O��B�e�)�N�`J�:	�œ ��b�E�)C���!:�1"x4�������������W���ik<_���l��i��鶭��S���O�<�FG)x��w�z{KO-)�W�TR�#�v���>bX���|�y����DPz�(�ݰ�-v���͖�0"P.>���Z�m�K�������'�?��_	*��a�#Q�����?a�%���0�������������)�쿡�b���������G�G���$��*P�_�E��-��������'�_�������%4������?�����X	�����3���7�ᨊ��5��0�?��*�V��/$���_������j��N"&ͥ��0�k��e�W	&��:k+G"ܘ��0�v�'f�!��3�� ;�n$���<�T"�!`o� �q�����v������x���n�Z�6�u��Y/�Cђ�2�[�a�z�6Ҥ�PF7ŝp*8���[p�~�Z$~T �o>����%\�|n�+\g��N�/t�O��HތD,�a`X��N�Al��/�,V�wݘ/WH���1��~n����Br{�d�3�o	�5���j�|�q���'�E@�LA�F���N���eķ<OS��ܛ�jo�d�t���|��9���v<���Y h�ܯ2]!��Vw�"9��vϩ�նS�W��5C�=����_+A�_@�W����aP�U���`�����?��j�������Є����?��������aJ�A�Zǵ�0�9�֔�v��N���_D�0γ�K��)��/��dО3�q��.�1�r@��2-��HN>��	j%9a3�[�e�+�C����.�h��@5�m�>������a�Gm�{����|d4a�Ga�Gmh�C��64���y���A������?E?�?��]	����O�MB�M���8�5���l?��no�4�i�r>������w�_����}	��;:��?�u���{��aZ��'5\����z����Z�C�k�=�K���+V��*ȞʫI�	%'����S���p�FCymц�K�-��|׍��{��5l[��@��C�^05_��F^�xk���Z�:9ǕG4�c�㢛��:�x��R�cv�A�F[VQ�9��'�.g�M�������s��Z �|�r�٧�l��V�g6;-�24B�������M��d5��z ���������/����p��?�P������M��:�+>����zd�Γ6/��13Ϥti>��Ee-�"^��$ܘ!?S�w=��L��Օ��k�_Q��k���=���Y�'X�ě�����>����+kRTݖ��#���Í�̂�� ��	@&q@QQ�ժ��O��ݻNp�V>X�%V~��\�#cN�i�]P{ZJwh�Bg���1�:����]ś�Ҕ2�3�K�5G�V������Y���¶����*r����X�vo;���|�j7���	�������Qh^��CE�6R\�:����bސQ�D��Z4"��ַ�!�z�r�v���I����u�1w��X�GT�ެL�<�(9�d�48�0B&c�3���,�s��ΐ����F�?�I��V�&����.@����_#��z����M��R=��?��M���!��|��o����a�7��A�ե�^V�A
�@����_#�����a�[B+F#������o���o��������@�_���fB�_= �����	�O�O�B�_	����ǘ ��y��؜b)�d)��8?DC�g}&� ���G3N�Jt@�!���>�,�����Y~��gq�ͺ�S*lm�m�H�)����ϵ�c�Y(�d��x��d��h}$��ї�Ø�qr�9��s�&��.���1Xo�՚�b�Hq˩$9�:8�����c*V����y���*�����n��S������ʐ��*����w�?��1
�%h��Ǩ'���+������k���������i� �����ߚP���:�Ӆ����_?�?��������m�W�< ���v�Ǳ'���
���o�a�w}�������z�c��[~��ݻ��������f��)yo�a���,�����͗~���"�����o�ޔ*7UW��K�s߆���|t����|����%Af*��������؎<����kQ(J�G����tF���󾿞�V�Onk�nk�h4G.�M���F��]��[c��s³�����n@�݅/	ۛ��;�7�H���5{�ȯ�)�	��V �t��SA����K����Z�K�y�fC�%>�E�qzS{K�k���^��ui���ݱ��"�O���<��-@�MĦ�_�=>�y��\�t�[c���q�8ܣ��.	O��4���I����^Maϭ�(w���b�td���I_=�h��*��;'��Jk�/��%��Wj��گf4B�1������J�3�g���w�g�Ǖ��')s00N���0&�����Z�v�g�r�6�W�ߏ.z��G�������͵�Ѷصy[���IKM�>uiByk��k�r�AW�[�dd@u��J�v��f�,|���qf���/-;Ǽ%ύ�f��=̤���'*����c���d���rb���=����Ūכ������Z
�T�=����#y�b�z�*
1{U���
�����Z�sՂ2�
x�KG��ŤNY��Q���l~2�N��B�%N��fԊ�XH��'���=x+�4���.�LnK��l�f�ˍ�Ҳ/��������M��e���ˢ	��'��?V��9�!x���e8���D@��i�[�q���E�W�x:z�����8��;���`��[e��&���������$X�=0f���n��uOP��y�f��Bw����]�wiE���U4������P������4��G���64��!�����ư��^ ���������R	��σ�k5hD�}����+����m���m��5�ۚ�,����l�_ćdxy�����c�����~�r�������L���ȷ�@N$[&iz6�ٔ����\�i�פo���B��+��GK���5�v�O�^�!;J�˃����+��.��N\�}���`���7��ja��L���Qh�ڭ�M-'݋�I$"{�~VW3�hoki~ͦ�"k�L�M��i��א7��u����(<_v_�A�Jm����dP���Z�tN�xZ��l���A�����Ʊ��ƃU��������w�v��q�w��v湬����D��+o;3��i8����%�dՎeb'�d�������#.�2�P�-j�����2����=����/��V��ݮB�N@����_#��$���&4��!P �����?���]4B��O����S	j����v@����_#������&4����քF�����o���?����濽���ڞ=��"�{6ef8��Q�0������b�������m����w�m�+��~�F��_����s����������-"ݏ:�p��s�EZoI� T���=v��
3�+T�V�B���4/��0(r�ܟf$_��{��=N�\�ƾ���}�Ǿ�'sߞ/_V����w"�%�[���͖���Y�*�M���4��]���7�N�s6��>f'�j5�P;�0d6��6F)�m��)�{����_�haI�N�u��˰5;�{����v��Q{w֘$�:	�F�?��׆Z��~Y@
�^@����_#�����)���� ���?�����7���z��迚P����s���B��k��_[�5��	�a���+B3�?�qQ�e�p$��s?��"o,�bIQ�s���Qe�������������;�?i��
�E����)�SLڣ�yg8O�S����������XG}����i�-a�E{{�>��3�ùN��6=�ta��|õ�"�il-��51Y�ۜ�Y1:kݾ�e���)��*�p�c��o��������hTq�?���U�F�?����?��������n�Ǳ����U���|>����������������u��w�T>��0�S	*�0��X@����_�G�����U�R��	�ơ��3���* ������������磱���k�&�?���C��>�B#��g�P��������u�?>�����O���*���� ���P��?���4�b(�8~�|}}D1a�>�a�������9�Q��c��
�rL����O��)��_~���ҡW����By���FN�<��։;T*���['Z:����_��nU+�e+���U4���������JP�C¯�������?p�W���������z��?P���~��|����� ��������&�?N=���+AE�������L�b$�q`��2I\��8��Q0$�E��t@h�s��6��'�	������J�;��G|g�?h��_�("����l��!�O>=��h�'3!|��?���ح�|�]�֭��_E#���?��+AE�?��6U��������
@�/��B�����m��Þ�`�_%�����`򷙨�� �OӰ��4��������W�������I 8j�?�����O�h��*P/��������{���o��~������ķ������GQģ���*���{������_/	r�]Qo�w�l���Z��������_Y���%��`5\������� !�E@?�jeqq�2��z��S&o�QY������A�(�3�?qH�&�Ōe�g�Mvv�"�z�s����A^�~cg-s��Q�.�^�Cnu>��ˎ�V�^�V�[N�r:|y�	+T�r�4��Ҡw!ϖ���__;v�9˪��묬�~�����/&<M�I@KD�� ^_�F���l6їAJ�{!u�u�=��^/D�	8�|9�6C�����X������q�?/��ٌ�hSjq���!�HvVܾ��G�=��1�'~�3���3%�1�����a3�߃�/�U���_����M�O��@�U����/����/�����5����ߋ��&�����
��
�����=,�d��U�s����\���^1qk�΅2�[۷�?��gj��[<�s���kr�K��u)$ߟG򘚠Ę�;�ݞ����@�v�����k��M��W岈&�5���߯��?�Ԇz���r��߁��&��(�ԆF�?���~�/�x���?���O��׺�$��`��hD�}���P��?��J�(�~�{�Wߺ�n'��v�Vٱnƶ1q�(��޿�����޿[����=[�;�w�`����j��if��a��75���g�QX�mܰ�t���01�q����!貿G����ޘ6MC.J)~)�n�Z��YCy������]�j[R����/�C�q�m7�b\p��8U��YT�|9���.[	'缅i�Q�/�I��k�o�q�����k�r�%jUp+S9zgb)�=m��IY�O�-?�`�Y����/�~���5�~���W)$ ���_[�5��a�gmh��������k����qq�����YS��i��2�����E|H��w��!7��D�׀Y�K}�\d۸��[>@���+��ή�0�Om�5�5Wp2LW�<;#S�Zxs�_d���oN�ޏ�|=)~��0lie&���Y�D�e�gs!�M);������zM�v�/��=s�|4uq�\ �ԅ��o/ϐ%����R��#?����,��"u���{�Ao�O��>��d�ף��[��ZN�%�HD�����fF������M�E֞�<=�n�:�������B��b���--���&� Tg�P︙��sY1G�H+W�vfȝ�ph�)K6ɪ5��N���s��G\�e:���-ZԆ���%�q#���;;��z'��'�즗���XC ~d�1HB$%~$~�s\Zh�I�@R�=[��T�vW%U��/��%��R�=�l�^��JŗT9��rKrN���(J�4ci�F�J���߷�uc�hc���}��\�̔�/��_W�����%�������_n�﹐�ܩ�x��W����}�:�s��������犒��o��������{����w=���i8o
��������B�{��ז�+��}%���s��{�][���������^����kJ�o�5���ty��u$���r�σ�1���Is������.�Ed)��,ŢRBt���t5�U���,�!��k��k5^F�HŢV	���ϋ����y�����ח������n��rZ�����D��f�>*3y���,����ba��\A;Vlqx��`q�o���^}Q��h����Q��֛�H5�L�ѩ�$)��)�ᣨ�.�U�W-�0%)[��n[��!������k�;�s�tq�Wt���{OJ��y�1��ck�$��a&�y���8��K�>{ B���% �,t�Ό�k��ږ�h	6d��R�4ᒌ,--�D��� �7d�.���j�Zi�S�~�"ċ��^B�Kr�rYrpj�.]N)X��b�\�\���]���y�f_��%��g�a���)K�l@��O�
���O�T�������PAN�j���ԉ��U�Ĥj����*�E�")�8��b�$��\E�h8�BRU�Y&"�XV��A��6���
퍗K��N���vo��V��ƺ+0��;hR�O��9�4ok�!�,IՐ��ImL[g�rij�)�3H�-1?��I���/%�Ţ���RYqS�.+�ڭ��)�ż�L�Ri��gB��R����Br�P�,ЕLv
39]m�����4d�f������F%�l���I.��73����i���v2��+��FS��{�j,��ޱ�u�#Y��i���j5�U��N��I�u����i���4�v��4����3�{N�u����	��g��I��;��I��i>Q(��б��ڛF�6@"-d�Br4)�+�����=l��2��rWS���`C7�`O2����F�'R�予	��9�>	;d�3��s
�d!�����r��_ɤ��by�P\���-yiOA5�۲����ԙq�9¹N��B9}�q�#�91��eKel�:��BY�%q9�w�F2~|�PI��q�M�ݰ�dR\�.�(�L��4j��F
�����bgcKr�2��6fN��aI;�"9��X}DUK'����:������7]L�%�K�Vs���ٵ+��4��Æ�;�ҡ�K#DD�e�w��B�*9D�@x�<��)*߫�����3�5��"m
�Q�J�c�9��t����&�y�8��c��N������"�]J}��_����Z�����?k�Z������W����~�ɿQȀO�c�7_����7��_��k��-dZ� W����¡hHA-q!%��G��HU	11��t��b<'�X�Q촰|M��X%�/x�Jݥ�|��/>k��k��~��O��_���ٓ��P@������?�^N`Q����m��߽N��u@%\�<~D��k�O^/�K��kw���*ֵ�ܡ>�C���uW'S�xcV�9�G�`$W��F4ZY�Z��4���J?�<u��3?c7���`lTC�Z��Oƒȹ�>�%)�80p�p�K�F{b.���8�0��J��9���ˇ���;6��vH�t�3��?:47X&�OF�Ms1s��:����A#���.o��;s�9��L%�i�-d	+�Ս�bz�Y����|���{(U��1 ߐ��
=��T;'D�H�U�?9a'�+�F�˔�J_ gk	'��3��zJ�ZS��YK얅�vW�~C�½�̶>��h�Z�s��y�fb`�[�}+�#���c���f+ac����"'w�ֲ�z"��n�>,��J�(�����T��¡�4�2T�F-�4K�s�b|<��R��䱏��m3�8P���@ߎ���lm�
*���uPY�,l���Tl�{tr�9\&����2"�o�l{*`?ݐ����g�\9C�v����y�0l�ǫD2\V0��d�\�v�����$kI[�0����)}���T7�v�`R��R9��g{��������[�dl˫�mnmFZ�JmGZ�V$���|.������|)�1s�z1�ˉ�T���_.ǳ9�s�I:�ʐ�MדBn|㘰/9�Qy��o4s�5!o�R7��c�(f����A�]BrF*:�Ω�*��$���Q��H5�.��J"���̵�0H���jyqQ�(�ołmw1���mU���^B	�3�����Ձ���bG3�\,�-���\z]��A��EzJ�R���
^*���A������(%r�2Z���]f������w�V1�N��Z��1�H# ��iT�C1�;�V=`r;���'�O� '�twQza���g�Q;Zw5����vC�q6����C���*W��A����c[i��T�ds۫�z hu+�V*�[췔�����z��K5~#<[����������Bm1!�8Z����mX�ť���g䈒	�C���S��#���=.V`@W\�����:�/��J����l�c�Y�Q�o&2�v6"���|��"1UX�TÕ�J��ׁBגR�Y�%ڽh�-��ewoا�� p���Q�q���&u��x�+w_�n���Q|��$��^�Ė�Z�x����>x-ѐ4��]�u����>��ͯR7���}#���	ؠ[�Y|�9j7E�ĸ�D�H}e��YŨ?y�`kgQ?~���oP�qR����?w��ޡ~r���;��$�f�2o#�����H~�P��L��N_�N_�B��x�&���<��H�v$y;��5}C�v��;��;f��J�2n��
�#�q�2�c�y�B#����-"�2T�^��n�~|���"���AQ���%So�#��,�QR����Mp�ɓ'̛O���w�+6LYm#�kQ�R/�YsԈ��7�d	cSj��m�c;��
�5�����#7cf����3��7�W1��~�T?�n�%��ju�U�qE�61�+2G��_�ۑ�,�-P���lu��n�N��g�mwpE1�i"�⩻��iQ6$��L_�Zz�&���祧IO�9+�����Lhb���/��J����z�^��Y���?�s����z�O�9w����uzA��S����yv�~0zǌ��!����˲�����H����Z�*� �A�P�����j�D���`�P5J��P���)b�P1� x�~n!��C�oxa?Y���$���
��c��`���w�X�c˼�a�A��X��n8e��Fj=�C�b��!Y,�z��w���m�hN�.:r�4Z'@I'0�1 �a�=��wI����~�xk��{�_� ?|*:�uK�L�j����@��Cry+-f�3���������H؂���^Q����7�l[c�ܭ[Ȕd�c6Ԛn)��� �@�aD}x����G�����lD��5AYH��m��\u�_�~�( �o��Jʐ��<���Az�Z7�8 ��PV ���l���J�J1!~@��y�o�;}_�;��3�v4�����{�f�T�e���K��{�Vj�$���c�b���]�H����tp_�dX�d�>֮�!Xh�uS�Mwz�aW�q�@li�h�-�¥�|����E5<�J�Fa��W���B���nK2ț�.Q���-�BR!Ah4@'J>�&¶�b�F��F�F�0m��)ݎص�U�;:9d��=�q�|���X�.<��*������Y��KᑙËv�؎�Ȯ�vJ��c��hqs�#��Z�4��7W��t��ɦ�S�E�N\��#���P#)��"�1c]�"�����?I�f�0g��a#�_�c��_�$=�����B����=Xjt-[��u'�:rXMpa���0P[�9z��P���g��ߨ�×�A�IDqۛ61�{o�U����C"<�oC��CRю�5�90-�ƚjz�-$i�K����l5:�e�n�d6z>10�������{����h����{�ڲ�0�p!&���� u()��Fz��47�I��%������a�O�<��������Q�W��׻�����s%�y��\%���:G>W���w-lF�)�J�H�]��Y�ӳ�5e~b�����:������4�1���W����;����=�<7y��Ӟ�w%����Y8�W�	�\ɂm�ް`u�Dk0�( ���lop�C		�<Ǔ[�����#-�V��d(s�Y��G���R�����Xo��j�l��z�㊏��^���%
��B��tf3�ǧ�'�-/<�7T�1��~h����)7��t��օJ/�U�2!~,A7��ףG�i஘��^�IP���ؼ�TP�X��P�7�% ��k���������؉��;a�q/@�Ĥ�hb�~I7��#X��g8�i��3�N���-�kM,��-��Y|����sV7���J��5����o�T�M�o�C�<�
��)d�!���JU�][��zG��[�f8���k�5��:r��ZSe�� �����
|�v�̶;'�o���*B��%�e�ia��T�0|?�`�EA_�h� ���D4
YG���6�n��K��H��,v�c��D���uّF����N, �t��>P�����߰m�"�����!�~�a�J����ţa���N&I��ao��v���'!��3 �3���ĝ)����:gu����IR�F�p�Fˑh��֢1T��jT�ql�>U$Zq�,1ш�2I�I�G��& ���kS�k�g����m�:�ae��a?���H��o>a�y��]������5�=��p9�3�S��{\Y��5�.&�Inƈ����t7(��~'���g� ��,ն�@>�,|���bǝ&��Π��mׄ���Hs_��9�1|6os�C¾�;.��3��<���O��-0�fo��������?�!���u%�H��a�řx�� ��_$y&,"�.� �G����?��H3�?�`��a�X�BG�f�����]���mGq$��~X��+�V+�<Yճ��ήL��\R���`�	��$H�V�c0���������k�/�o�u#�L&]YU���*�C���8wClo��h\H��ѷ&�����DoV���D\l��a�s����rT~]�_u��ڸ����]���1�&��S���na|ۘ:^ņa�[�"��l��"��O.�ApYO�ܕ�3z2�d�������]���x�-��ɩ��ɞt����=t��{2��	RS �
���;�����ɿ�jj[:��{[	n.�[;�y�/��s���iZ�uh,lоɼPS*���>ȝ��� C�9��	�s�F�B�/on.�-�;`_�Fm�X��z�Cë�����''���C֚��� �~���3킉���Ë~���3	�F�=�]P�k^8<�j�͠y����ړ�C@�f+p|Қc�~V�:D|{0c�����v���_ÿ������"	�^���ڰ}8�K`C���ϑ�)��5���&x��6��;Emi���m��}��}ǁeP���b�鷰�6$2��ú\
��]��-��k�2��|-W��bh���.i`�����	<}�������G退��h���0 %X�
�[�cN�l��>`��!�x`w����qF�_kdz����b��:�����n������z.Q/_t�C|�?��~�?�>�誴&=cE��@����;�7�$"҄����Q�a��?^��O��6b������8=^x4!�����Ҋ�8���x�_H�����Lsn�w0:L�������"m8�:j׷v�p�uǶ-��=��i�8:X�[z�	O7��[Z���n�s8����O-����F4p�$ǩ��ӝ�p�;ݭ4�u�̥��1���	�m<��9Q��p�,�B�����c^�1_��!�L��$�����}K�J���o�����/��ÿ>Q���#�1:�s�t_gu�π����t&��k��R��Y�O�-��u�g�L��Ri��҂�濿���-����P�"Nѝ�ݢ�|~����G��|�����۱O<���y��o���7�}���19�>27Ջ9�v��>��^� >���s��e�����/b�t�y����$����:�4&4�3Ǧ�P����e/u:��~�qj�o�m�B�nZ��;?�7��3�;g�M�X�R OL�A��m�^�*���(��]Eo+���o1��9|����ǩ�1|���L2����'R$��,p�?bH�e���t������Y�����4]tH,\,�Aa��1H`eć�"7��0*��S0����x����F;���AƝ
G��>�MX�/@��?��?�Or�T�T8�>8|�����ޤ�{����+Ϲ��(_hq�j��}B�o�t��H��j���D�~�����jS7���a?v{��
�P���Q��iMi>�!�)`lp�CQ������&�;U�b�?��^�������V�P�Fj���UB>���v����eh��N��§���K[x[��?��UX����MX�5��:r$�����.�at�9���[�7:�>�lS�\�X�����dDڽs`�C��`�l$](PcE�Q���Wr;(-Y��gͷ�mL��S����]N������C���?1w^��n�!o1G��>:(��w��-�#H���[ݚ���;�*��\���j��\ND_>{!��r/L�G��}��#\?��D8sdv|Ba��>:X䎸�Mc����"z����y�.ZAڄ?�)v�]LB���膺il=AK�LB��זe<�Lh,�l#ˎB��a��l��Y�p� M*΃w�G�6�je���]ڙ�!�[��'���`��5g��N���K�ܰ�f{�p��	8�!�]��E�(�|���vY�tJ�����Y��.�����(/�[��;���aA�J��.�z4��o��vg���4�A�iy1сŻ�;��76 �+�z��¿�9�;J�����7wl���e���`l�d�-�O"�K�{p����Fu�c��Ƌ� ک1á �y�����U�mk�`�������Q��ڃ��ն�y���"�?��DI ����6Vo��}Ǯ�$.l�6�IӪ��=澐a�I�����?Z��ar'^�߶��[Ė(�Qᡉ�;@r����|������R8#%tNn#-Ksg���a�����Z� op|x��zݺD�jS�����-VXM�7ٶ��L�\
'efo3L��S��sN�m�� ���[�D�
����Dd
�y1E��"g�3L��I!�8�_�8>�"��y��8�sD%D�O�$�S-vt�������>�ߏ��t�o�����;���Dq��O^��
I���W_�g���Kd���7�7);�lMF'j#b��k��x�ك���l�G�Oԟخ��q>h�~��?(������'��p�����d�?ā�s������s���l���z �������9�O��0��l"\�'�����M>��p���b@��v����8�q�s������������G%��Th�fM�+Y�)!���d��lV4
��+�h*5��yHd��yr�x���eZ2k�$��l0V�k��8�8���T���=�jٿ{hm�
ٖ���R�˻��]�ca�i�mU��g�J����B��k����2�6rW����Z�w�!�F!�酕]W�ZS���+��+�6T���+�F�gV��ȩ��J�u��l��p�
ռ��n�;ɬ<Hb�)�M���r0<E���N{5�3kml�z�ϋ�Y��}��i�f}r7�ƕ��U�j=���s9�+u�TIp.�Uy��wڬ�Z���(5?�e�S,9]e3d�b����sbM��LQNL˭�h��o�r�Qf����T3�"�S��6k[J����Fi��f;��]�]��fi�������n����fr�o�z�	*�Zp|*g®֙{�V��D��f�g�wW���f݂Xk�%_��^�K���`�ġ�Rh�uU�i�*�_V��H͖D���xc��F��|�rZ��x�;CڌM%��*��D��V�V�UE�6+4T>#AT"���\�*��Jk�29u��X��QKX�⁛�5^�W�~c��\ʣnI�$���K��L8
�3G�w�ˈ�cN����%F7��TH�j��B�!Wr�OɥO��x��s�?I��s@�?��b��K<��H��y�%���C��Վ����M����6Y�t����s_8�W�6�7��>�P�W���-�H!&Q^u�Xv�����-��8�o	S/����ĕ��l%�Y�n��҇k{�W�L�ȍzZ�s9��N�fc��$�o�[��^��q�r��w@_�%+}5���y��XӘͣ ���b� ��(�9Wn�[�����F�b>��ˊY3S]G�_e�� *Ӓ+��c�sm�X�p�z��$�Ġ6�����wj�Q�E�,��%����B�g�;�S�����I�mf�����Ҭ0�*�c9%.sv�8��P-=X�V�U���T���@��g��tr,)a<�?���Ā��#c}���
!�����?"��|��,���/+�%����
EєEUR�:и��w�xm����j潞P�ՕWm���IiJyW徑-�{�z��g�W�Z��0����(6���X4��憯^5��|��,{���UYL�b+v�Wf7��B����fЙ�
��~���	nzc�L��,r���~ ����lP���A,���q1����>ls�)��!�?C�?.���D��Ā��?lv���
��B�/N���qH�B�����/|���s�%B�<�$���K����ӳ[�o]�,����պw#��c�r�]{j����\�Tq�tj��A]��Q�fvTh{�%��-��C�<ӛ��̒
�>�/:���p�U�)>��\Ȭ�y�}�G��6���1�bNA�)s�U��zEm�~e�pjSa�M�k��!.c�eT{(iȖ���ljkˎ���fj�o��u��Z�RҾ��"J�E���jla�j4���LU�N�=�dn@���;�8)��)���w@I,�A�aY��ꦺS?��4R������./��_6�RY��l�9d��khm�fNT_t���.X�$E�P�zy�Ƴ�a�
�V�L6�T-�N(� ,�����*��J-˻�Z����Lkv>6���L�W��"�I��?d��ލ����tƕ�u��;�Ȋ�fR�����c��|&��UZu�������Ǧ��$��,��GDp �����ł�G�����,/�O �"������D�'�?��/+�?��"�?�1��t@������n�/���^ ��|#���g��"���!��>��fRD�?�$��p���.�;w�U�t�ʳ�2ECp�-_z���H���J�6���B������(��~v�7
��>/���f���W�����F5�Mv�\z4r��M�n-�{���|��]����-��2PZ���چ'�w�v�x5Ҩ�&��,��_�z+	+
�r��6�������Yʕ�"�ɋ�8�1ս���'�5��Y�;�Q0����]χ7vk�I ��G�2i[�\Y�Vr~eN����s�M��0�J���[B,ۍ�W����j�fu��%ej4e��W�n��KSĂ�#���A�?�v�
�R@�������'���A��?�I� g�X��$��ŀ�#��H�7�������O����#c�z�� �����_7�����|����g�8����#�����J'�t?�1�:����%�+$�=��	���N��Ʀ � �R�����_.ā����������0�_.K%Ǻ�X#-Iu���`�J�m�K;�3�M�T�p�0�g}�̺�V�>U[�MdSW�~���+�0)�a�Z���Z�ۆ�z(r��ړ��,�U���.��Z�u9Wl2�ؐԁ�fI�Ϗ�8��,��K���NO�I��8�9��3�?!E俳@,�����H��3�y�?I�W ����K��c���Bpv�OR|�
�E�?5�C�g����� �?��]x~ā���������#�=q"���_�?�&���.��$�'n��H�|���z �?H������ ������#)>�
D�����8�b��������X��G�0$��Y��� �?H�����_G���;��������X�ϑ�y����8�Nx&���Og���6�� 4Mc�4����΀  ��3F�I'�Fh=�$8������9Qu۞g��UG]u�*"(�����.*������I���+Y�8�9�Rv���7�7��I&�\�!���P���A]$!��%�3�?���_������3g�#T���1/%� g�fL�iC'3�
_�?���Mֱ�?Y֙���Jm9�~�f�b��RB譓��Nz(.��^j��4ʏȥ��=ط����V�HGn{(�*���^���G���O�8�����p�_[�u����?�����������U��{p��_K�ן�O��)�x������rP��)���,��R2Q��hİ�F������1,�4���_���ǐl�A����C�kP����?��3����1IV�d�-G�}{�4��h�l��S��G��y�?��{��������@�����@�FD�wwK1��f��d�M#w���<=�Q�Z��|��ٲ-�	�7Y��us)���{Q��{����RP��c��DY�?���0���0���p���k��맀�(���������ԁ�q�A�O �������+zW�ñP5���������/俖�����ҠR ��W��؃��,5���������;������]����'�K�[�?�,�|L���Տ�]K��p�N��Q��D>N���J�����KYr�Ǎ��� C�^��`ȯ�̇;�����K�?�T"�%`o� ��C�����7�]Fh�l�/Ѕ���~Ci
Z�P��jnYҠ%�}��q��&�4�踞����dn眱[����$v��=;~��>���W�� 3G�P��[!���%���caXw�v3����:��c��n�	�s��*��a�r�i�.�OX6͙.4De%,��Z<~Ը���O��4��l��<�Pm�_+M6�wξИN���$�HR�+$���fL��y��'�<䚡���'����.��6i�6���Q0��}Z;�&��U�Ec���ߐ�Z
j��|�_e�������h
�_��/����/����?����-�S�ߌo�:���Ѱ��|��oo��p�ɍ�ʎ��B�� ��5G�ݭ��3�)+̳���ϔ�ݓ�b�o&�k�r�í�N�%��V���!�E��0�4[�Ӳ�Ѿ1�촠���ۦ̣�z�����?�T�����r����u8�Q�������*C�?O�������������_��KA����'AH���_����"���mE��~��G|x(�;>�qM3�I�e�?8�[�?;�������-{|�����E�����ۣ5Ӑ�~T�ehGq��ogn�j!�K)��Zu�\�2Z� ����&�9�]m�6�����֨o�V�0t9j�"�놼���w׶ma�:��sKw.�f�f�_b��[��{c���_80���	�>�Fp��0�,h|JY������
!͖��P�O���H����5IA��'&:ܸ�H�*'�����85�f���JC-����?����?7H� �P�o�W������w)�����. ���ߛ�߬����|�����Vc�q
�B�M�$�K����+��I�{��ɸ1C~��w}����*�[�_Qئ=ع6�?���M�_k�jG��Z��5��Y���d��sjGK3�;B{�]�cf9ESW�5��$�t�a�u!��Ũ���CʧV\h��P��<�B����\�_�m;��a�ҭ��A8d;�.
-ݬS+�U��ۢ�B�	ޡڤ���]y1��#Q5E2�L�x��!ɺg����l�4I�Bke��1w�f����YjtNA�d�ڕ�B瘽�L�z���I$9������؃�/��Y
j��|��� �������W?���F��A*@��G��i��2 ��a�7��������W��{ZW � ����j��������Z6jQ�C�[e��7���7�������@����Ex�w�6��@����_��������ԉ����?���Gi,�X�#Y
�8�ѐ�X��}��/$�Ҍ���>�SGxh��;����?u�����������6?&B�o*M�F�,g�3w\�<� E{��M��[�'���@fO��ǔ����$����n!�Y��.&Ǿy�W�,]��o)�c9��Q���Oax�fLŭ�~58�nІ����7���6��)������J_��@�}=����^����|x�e��#�@�W)�����Ms�E����0$���3��V�r��9��.T������A���KAU�]�U�� �����q�����RP%��,~����,����7�u�����.o�w���A�g�[ψw[e�Ǚ;��%��y�g�)o���D���tV��[��r��^"�}����7�Q��m��9���(	�ര�����^7ۑ��7=�&��T�rv���me�덃���4V��vcvc��h �F���2�'i_C��їn�&\��Kl��}J��$l�yo���$���i4��Ϗ)�
���/=M�SA0G��s��_G�Ղ��-���u�#�I,
̨;n��`nV���A�*̸sh�M�1�/m.��_ ?�������<Ɵ�F�ٮ0�l��~�8ܥz�v�T��E�(�)��EDU�S#ϋ-��3�tvD6{c�k�4]�����G��h��P�G��_E�R��.h��Q������W��Ɠ�;���qH��j�0{�n0s	�΁��^���O�f!�/��b�ں��B|�.��ūs�Z��[l���/NKU�����TZ�a�ƾ&�9���2ҧ�����Vn���,�|d���1-5��sc���%�YS�I	�.f���(�Z����	g�c�ɐ�=[�ا�ߧ�^wz��-/���|�������`�铇��.�P�
36�Z�U���-(�Ϻ��
XLv(�;�1*ۼ3�'���)B.q*�2�������PX�)�wS����3Ϩ#7%ry:�osVOZ��??#�����B�������E�?������@�����n�㭽2��vs"�Hq�4����.�8^N{"��)�}<�^�CM/z��.R��ft��)6���#��Ǉ%�*�͞1ڄ��h�(踂B�O��"��;���Ek7�b���E����U��W�g�_;��?
�����_u����$������r�'�`�K)����>D���Z�ѻ����o)x��+^��x?����NSUG���]����x?���_ן��:�����}��U9����W)5f�|T�G�X '�P&tiz2��ɐ'c�]^S�_�~�V��r�ֹF>ں�u���յs~����呲����l�/��u�˹C���.Ol��;������V>�cG2W++4����N��:���B"a�wN1H�hwc�}~�&�|�t�������A�k��|��U~u�/��~�\�B���N�:��f�Tc�}<��h�`��F�EU�cFu���~�j]���x��k���-gv��b8
�r�bD "�Hݍ����`0�>��$�j����NT��#u*v��ͰE�P|(�T�v����6�Q��=��#A���*��{}. *���[�Ղ�I�+BM�. *��ߛ��������Z�?����JA����V��������=���W)���.l{�
�����o����7��W��������Co�'B_�O��&t�w�owX���/���]PO������{�c�+�;���y��{�����w�}߮7����M"�YmS8cJ���"�iH�~��M����}�.Ō^��޴�HR��$�̧y1�B?_����!�����$U:q��;������f�F��]O>���7�E��8n0��me^��'i�X�������k�c�7�L�Ӣ?iy�p6J�1��	C.&=Q��(�5�<]�
�.����k47�k΄U8#�a�9���:�M_՗Vs{R����\�B�A��2T��v�� *���[�Ղ���_j��O�-@��E��o��� ��� ����?��"T���)�e���� ����u����C�{I���4�a!�L@�>G�x����AD�T2l��$�G�ǹ�ߡ��P��Q��w�U?�<�����Y>3����iH�M���P�"[Š]���p�s%<��8�О.��?�U�3p�ԙ�xC،ؼ���Gb�b�a�!�C���ZR�n��X�w4�ZΊ��֛5�btR�ސ[�Һ�@��{����+�@�Ѡ��A�ߥڇ���P��|���?����cw���KB��>���,������� �������E�F=����)(���!���������8z��������0�_?Ԣ��������������C���W����/����������P2��Ͽf�E��������/���?���������w����O�(��2P�O2��?��KA	�ʥ}�i��P"bq���|��ńa�y����ˢ���X��]�.�`,G���Q�������E��/���U�t�na��Pn��"GN��K�q$����/���v�����m�k�
�h�
���E��!`��"���p�Wc���߼�����	��2 �?0��?0�S��{t�C��+_}�?5|a짶(������	��/u��z�����r���(ԣ1��������w-1��y}fvv����ƽ�`���e�d���F#��8���y?iid;��ı�؉+jiFiAsA{��=p�� {Y�sA8�7�NU*]]����I��߯��ɗϯ�����U�$tL��IZgM��Q�6M�!	�T	F�uJG��Tձt|Y������0P�����?I[&�i�hk������Zq��&F�P���dv�n�7�����*��U�U�U�*�����	��������f�?��Ul��?m�/�7��a���������m_6�_N���;�M�����I��7����̚�����F�1���p� y���?��ۦ�8�������J��[����o��c�����o�����Q����quw�����(�8G�#v��e�����g	���>��h���k��k��s��KY����i����>(;��>;iU��>@���>@���OTG�����b��cY3���̙���歷:�`~Ȃ~��{��h��W�����5sN���>��ZK�cʨ�;=���u󁅟�W�0SZ����k�ra��K�.b��4W���PM�N����G��j�a"�v���M����т����h*=I�h���y!:O�FM���:�M=�HmI��o���Bp&q�Ǳ��ľꕳC�u����n���Y����=S̪酒U���(���u6�w�)֘��:��j�L�*uj-��-��s��w��/����.��*����]����A�o3��_0����/h����6�}c��x!���u�	�M�Y�����b:��;(H������[Q�AJ�K����4Z��U�0�F���I2����B,�kP`�*b�j�D��2x5ޙ)�|B��ìҚN�V������C��a�ߓb'�?�������!�� /8v���0�ck�	����a��߷-�� ������:����C�!��f,�ec'���y�	���e��dR8�����5�\�pU�M'�YŪ���sU�{��,�_-�o����%��(�Ngc���T��KHIU�ӌ�Ͷ��BE�Ԗ�zCT?�`�%��Lk��LԻq\Of:,����c%4_�E�0i�r�O-�-������keʳJER�R�é嘓��r� $Y�p�6�ꖐΞM�C.,s���9�.+�&q�d��t�4�fAg��}<�M���U�(����|v��+�l&00�⦪T���n��F�1�lb%%Ժ�s�ƽ2vB��(X�cKغ��v64 lP��忝�����ְK��[|�.T�7	������2�_�-��U�_���KRmP�'����|k�-��D����\�C +�i1��ks�*GZ�^Ε�6ڑ.L[U�!�c[������D�3�jP=�����X�y�x㮜?� K���Ԝ���jr�tOk�Ҭy������l͔�8S����xјt<�\�����?�\���.N,`a�H�����d���kgRJ_��/>�Ӻ�<K�{����b0�T��/⭴_�(�v��C��c��]���<�O��/獠�m�huT������^?�V8��=^�_���:��B����h����du�ӛ���n׍l�ѯ�:C1[a�Y���Q[3��r��9+Y%�L��[���Y�����(��U�Dy������}e���������F�u�OW��E@��Ŗ�v�����@����3���
vB�?����l��7��������忭�G��	`[����-�������a��?��y���m�������o��������m#غ��7f~����oP���]�����'��&�;��dIFW	�4iUWلjtT�M
�hR�(��q4����ʠ�I����`�M�Y���]�������,�V�6S�I7��[�!3�4:�b������l�Y��2Z;��9�ͼ&�M��>��8���<>�X}��>%�ݡE��2�v��<a�޼V��aZ�w�x;l��9�h/���^)h���O�+��F�)]uO-��8àP���x���1>J׻�0�_r�K�8s��S�@��	\f�M/��S�ߔI��+�Y'Χ#��؞�wJ����Y��U�yb���=4Pj��Ir�I��+]���f��"W�P�I�\��BU�����z2=^[�]5��䲝Je3e=���a��(j��up�ʙvfU�.�*q|z���%,�?�T店�2J�n�=*��]�(W�|���u�)�̖��r)�S�mJ�Xv{&J��|�S,�mR���0׫V��̑��_����Ž�X�H$8���8N^���Ia�/9N��:ax�g����h8���
cTHѲ�g�����V�udTF-Nk�TH?W�� Z#��2Ȅ:g�����(��6ja��
��%Y*G{%;�x)O���,3��f]�UԞ	$�L;J��]d�}q��]��#f ��[��?�Eצּ����$4aF����ZBgI�0���	�U,����1�ʪ$I1w�c{��k�����X�������a8�M����S PT
�y>��q��k��.pu��5%�p���J���+��di(���_�)�\��S����ur 8^L3����k�R��Q)Ǡj���-��pk�7�pWu.��Mf�d������,�x��Ƌ��/�n��5��a���`k��m��!^������8����i�_��p��?�$��4*��T��VSY��aM�>fd��Z7�WH�Sr_4�I�ݜ�Se��y�Wb�\�?�`�r���vx����kU%5�Y}t���=�m�����������y�?I����|r������|x0��v'+�-L�������=w�8��i;���7��j�����p��=��у{�,��ۮ%u��v0��\W��a������a����˹��}߽�a;��5-���뚶�׵m�w�kܾ�^׺��5���U\Ӿ}߽����{]�}��&���:�}��F������~�����e��o�w5��/�/��I�g�?p�DBH�7 p��HA��/�?�����w�K���u�����|�����w���ߐ?��g�>f��^����k{?���~�Ճ7���j�v��4� :���$�ah��H� �C`�AS4�a$K�:�S��D2>e�	��
א}��'_�9��O�}�G���aX���у�"������?��<��"r?��߽�|������O�����m�ꂋ!�����_�����/n!�r|m�ߐ|�27hi�-���f2���D-8Y6cP~���se0�ϼf[���2���TU�e�;�%�.�H���O�䌼��q�tp�&�q:L?L��t�C>�~��\;�Sm3�xx�ҳ~�(*�_�1��'�����t�n<��6��Qk��y�t�Zr���p�B6�a�X_�y*�L+�(��r��&R]U1���vfz s�#����G�Zi��_��|����Z�-XϜ�֐�d���8#����*7RG��Ra�#�iIjz�|����|l?a6�ŝZ/�[�h�8d5���=�YCR�;z�5��'� ���^�huڨԂ2�v�t����a�礡QAɔu���wz�Ǘ�M0� �xA�[��J�Ñ��Rt��.}Q*��KFl�v�i���Y�7�hEi�NYpg������	<��F��=�a=�(3Ӻ2�g�1=9�I��� �8��}�Q�����fל鉋��LvB�x>��"��v�Z�{3g��<����������r��vC��TM%������ýa�&U�/g?���<�a�g��%Q�5Q�Λ�w�LA�z�ә�D�D�4:���b?y.3%�&b��l@R|��Sn�a���"�l����5�7M:J��b����t�]+��"�fR5��)�	z ^��vd���`�	��K{/#�"{�k���콴���J�[m������@O�EclO�����������06�,)Eϱ��>���W���s�7��/��Ǘ{z����nً��U���	<n3�O�]�����w�� �Up?��o���R|��-���?���}1�W��2XH������җv_������d⿹���I`EX��Bїx(���H�?%����yZt[m����'߆x(2?�F+�W���,Z6�`l�G٣�����_7�\��'~u64���k�U�s�Ք�:�z�b��m�=p����{�^��x�hN��$@�B^����"> _�>���؝#Y<��oDR��e\�=xx��9ˁ�sNV����,�{�[�p���+�����͌�wm��ˋv�,D{�$���~��:�j�.7��L�GK�����.��˛�u:c����}�ޚL�{J���E��*{��?��S��:�f��,�ߝ�K�qI������?������G������X<�n����ۺz�[�#d �}���q�v7��c��X�C�|dt�޷������E�G�wj�=wr����wn�8�,	�Ǚ�,~7=�vw�gr͆�\ˋO
�b�ɂ_�h��LI�'8��R��U�������G��j�᪪Q�*EeҴ�놉uSU\#��,��L�di�$�����~-�������9q#��ϧ�S\yl-���#���k\�7�J�� ��b!)#	���|�t�Hd�������v����WO?~=#�<
�B����Б�4q�0���&�T-�M~<#"U�"�t\F��E��d�m^�ۧ5�8�ӽ7t:��[�}�ڍ]ֲ���R���:d����֤S���اM���!k�ݣC�S"��h[�nH��FHc�񜭈��{�E����欷��M�^D��	ބ�.29\ʢ�\X��q��&5�3���0�����9�NNǧ��c�i|U���ͳ�a�ѨS���Rn��G�����蠆lb-6/)��c�+�L��=��7:K캑��_o���Fn|~�lb;�Mt?��+?��L��_���B��պ�&�:b5؊[��C5Mŵ������׼��w��zI���{1���J��{o04Qɏ�gǓs��]��N�����XrJ�0̣��u��'����g�N�9ۺ���0���<�lUW�S���'���Lx�7��i�v4���~��'�Ѹ78{�?��������:�MlvIc7*�t�tĹG\���w�'m��rL��Ɛ���Fw�=��NϏ��q�op�;1��9%����=m�9<h}VŉϷYG�J5���g�sIݐ��pc}���&^i�u�D�u�z��o��%ԋ����s����"$�݊(��,`�N �f�,��X��:�T;��u����I��{�܊��-���G���)tE Nbuq�E%}��S�M��2�m�?���DI-�=-�������n#��LU����?����S�*�Ș����txƹ�_��;^D���-�A�.�-���"fA1�f~�9���w~��NHu�+�|��D3F��s�k�}~[A��|K,������x���hp1�?����w��k���Z�Ȟ�m���	R����{���v�}�f� r	��^���,���C"_F`s<�B����rHnf�#��)	��j��~M�0�a�k�i&D��x2�7��[�r�ɋ�|_a��';wE����e,(-�щ��\/��W�s�10�xɘ��K6Q��ħ�v�"Mk�����	w��_��	$�2���,��c[�,��M��9m+���ÅD47�$/ya����G�r��O	�����W��T�������fq$\�hې֝!�P8b,	oÈ�;`a����1���_; �V�"��x9���X��x��W|9�C�e�����5��eՀ��;�h��:3g��8�2�W+������$����������v����xE������<�B�sC,�QO�������?"��ٜK��2l�������������_���������VĞ�}������d��x������u��5�T��V+VP�ȧ�_�VH\L3�G�S#��Jz/u���۷��#�o)�eI���*wb�A� �jm�	&��n�B�����b�jx�x`�mI ��Ƚ`�%iâP;����1���k���J��t�� S�C���u��:<r��g���/��ZɈ��fU�V�
M-�_��aݝ;<�/ֈT�I &����_�,Ϟ�OVL�ւ%�z]��W@d�������Nu��hH��y�F�V*H\�Z�|�g1M����6�#~u}j������?��_C������d_1kz���<���@HD�d.E1�+�\S�e9L��`�mN7��nw��m1o�
Eg��(8lx|��?��5�a�gѱ�5vws�����W���EaR�*� Zr����	�4����0��d����K��芹~�]��� �R���-��}>$�1�8�r=��u�z�D)*Z��! �����E��5�_I@�F�h�s1�%��:`ԡ�f3c��Z]�^�Rm��t�b�WlǤWBߍ�a'D J-	��� *����̀Lcǵ�bn�2P����݀T��!0`-�t�:^ �_���̳��9rbK�n�kY��W�W�qdQ��JĐ�"$%����N�
��������
��s�^!m����u���|����"���B?�#����	*޺4S��H�"E�)R�H�"E�)R�H�"E�)R�H�"E�)R�Hыџ͸- � 