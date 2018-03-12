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
docker pull gmoney23/ubuntuplay
docker pull gmoney23/ubuntucli
docker pull gmoney23/ubunturest
docker pull hyperledger/vehicle-manufacture-vda:unstable
docker pull hyperledger/vehicle-manufacture-manufacturing:unstable
docker pull hyperledger/vehicle-manufacture-car-builder:unstable
docker pull gmoney23/nodered

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
  gmoney23/ubuntucli \
  card create -p vldstage/connection.json -u PeerAdmin -r PeerAdmin -r ChannelAdmin -f /home/composer/vldstage/PeerAdmin.card -c PeerAdmin/signcerts/Admin@org1.example.com-cert.pem -k PeerAdmin/keystore/114aab0e76bf0c78308f89efc4b8c9423e31568da0c340ca187a9b17aa9a4457_sk

docker run \
  --rm \
  --network composer_default \
  -v $(pwd)/.vld-card-store:/home/composer/.composer \
  -v $(pwd)/vldstage:/home/composer/vldstage \
  -v $(pwd)/fabric-dev-servers/fabric-scripts/hlfv1/composer/crypto-config/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp:/home/composer/PeerAdmin \
  gmoney23/ubuntucli \
  card import -f /home/composer/vldstage/PeerAdmin.card


# Start playground
docker run \
  -d \
  --network composer_default \
  --name composer \
  -v $(pwd)/.vld-card-store:/home/composer/.composer \
  -p 8080:8080 \
  gmoney23/ubuntuplay

# Wait for playground to start
sleep 5

# Deploy the business network archive.
docker run \
  --rm \
  --network composer_default \
  -v $(pwd)/vehicle-manufacture-network.bna:/home/composer/vehicle-manufacture-network.bna \
  -v $(pwd)/vldstage:/home/composer/vldstage \
  -v $(pwd)/.vld-card-store:/home/composer/.composer \
  gmoney23/ubuntucli \
  network deploy -c PeerAdmin@hlfv1 -a vehicle-manufacture-network.bna -A admin -S adminpw -f /home/composer/vldstage/bnaadmin.card

docker run \
  --rm \
  --network composer_default \
  -v $(pwd)/vldstage:/home/composer/vldstage \
  -v $(pwd)/.vld-card-store:/home/composer/.composer \
  gmoney23/ubuntucli \
  card import -f /home/composer/vldstage/bnaadmin.card


# Submit the setup transaction.
docker run \
  --rm \
  --network composer_default \
  -v $(pwd)/.vld-card-store:/home/composer/.composer \
  gmoney23/ubuntucli \
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
  gmoney23/ubunturest

# Wait for the REST server to start and initialize.
sleep 10

# Start Node-RED.
docker run \
  -d \
  --network composer_default \
  --name node-red \
  -v $(pwd)/.vld-card-store:/usr/src/node-red/.composer \
  -e COMPOSER_BASE_URL=http://rest:3000 \
  -v $(pwd)/flows.json:/data/flows.json \
  -p 1880:1880 \
  gmoney23/nodered

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
-p 6001:6001 \
hyperledger/vehicle-manufacture-vda:unstable

# Start the manufacturing application.
docker run \
-d \
--network composer_default \
--name manufacturing \
-e COMPOSER_BASE_URL=http://rest:3000 \
-e NODE_RED_BASE_URL=ws://node-red:1880 \
-p 6002:6001 \
hyperledger/vehicle-manufacture-manufacturing:unstable

# Start the car-builder application.
docker run \
-d \
--network composer_default \
--name car-builder \
-e NODE_RED_BASE_URL=ws://node-red:1880 \
-p 8100:8100 \
hyperledger/vehicle-manufacture-car-builder:unstable

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
� ��Z �=KoIz��L&f�� 	r�S
뭈�'^�TT�tF��W廋KY��0�:��I̜����Fp��g�I���h��:n8!V�q��|�Q�#��;d �lmEA���&0'�q�%٢�"�m 2�A̢��'c&>�\?��m��"� 
m��Fu�&n�����aV��{=����nI�}��+�0'4F�1��ߡ����~���v&�
��� (���ϝ0D���צg���_���bm
jB �La�$.]V��d8J!c�F^�
�lE)���'�@<+u}1��D�Rq�}rFCp�<GTzsk��FcQ�
�7bV;��/�9E�a�d�||R?��@+:���ȋ����4N"��cq29d�@��\2?6g�[E��Nt�w:�T1�m�R	�φ*pc2K�\P��~�z�!�k7d�!���#%���3&FI��ݠ>�bs�H8�gWD�"Ac���v�C�.�O TNSzȯS�� 4�{D/Q�@s�P0h,�̉�� �EA�G�a���F@��+�D�B�k�ЍX�#'�ĳ��$��#;�hr����C&���P�|�f
ƍc����8�u�����Aci/� �)\,���+��4��� ���Vl6sk����;���*H`��A����|�{�_pT�$�O<:��N�^�CLC�<66p���i�˒3Tp嚹G�g��߼)�/R�3����I9���̒��JVS ��5�X�����<2d�J��(d3b�h!bT*	c��>�|B k����������'�],]��
�:��7�C7�'t�䭎d��x�)o��̱�s�涸)'
ˁg}5��ͩ�b☾e8-d�ٟ;_��}Ώ��s������zd����r�r�S��2<�t�RT�%�1�`�H��F���Y���ׁ�$E�R���0t�w�+��?������W���>Wc�P��g�dC���[��űV���5����.��o�jp�>F5g����ʕѶ��/H�n-n��3�4E�7P�Im�j��+���aJc��瑜E�zi�#.�
	���%�W$�"����%gHG7U����,R� ��";�ذ�%ڷ�^�{�j�H�McE�FLFpH�W	Җ%�q1օ�@��"�ƀ�3X��"�r�M�K�< 9d����>���{�>�d����&�݋�{R+3	�mR,/�4�A��ϴ�Jkb�!��+,V���$�!i=�T����$��,�|��#Rz,VwgG���P5L����T�_!�ʳ��(�9�<�����7Y��;� ��ߋ����K�/U�B6���x�	��B���s	�#ݤٽޅ��4��f>�̍	��Q]�P�X� �L�]H�䍪&�]��a
���E��y�+^��t��j]oc�к^j�DI��'��:���
9�~d
�+1Y2b�S�][��^�g�	n��~���v�d�)�!�dcc�U�D�u_�� I�o�����⫔�amlk_D��[�	d�Q.������n��QY^$�uz=R2�GM�qѶ�A!���Zg��s�z�T:$0�
�OSXԛf�p�|t�B1���t�+�3��!��Y�YX�m(yj��]�#L9��t;�<�`?z1
��v�*�oh�}ݻф���|�L��+�|@A��!�t��Ceq_�X��U��<L5"��0�R]6�bH��	#D!a.�J�<ͳD���Q���4�boc{:�r��-��6��/J�-0�~��kk��s<�`�%Y$'wl��ӎ#@vŵQ���,9x�B=�1��{tO�K�[k�L�����*�����NЄ��[�v��Ùv�;�X=�$?�!��HĐ�����1��o>��2�A�˒�WM�V`�GKvf�E�W.����e�ӛ\�n���u�����w7��Gfלld���A���s
Y��n�5�<�/$W�'�9��}l���&g�_�1�pA�\deqH)�p#��F*}{���)��oN����3~p�Gn�#���ɹڮ��|Z 8�N�ܹ���\Ls�n�����C��;K�)�0���!�kF�W���zg["��)�s��)6��yF-"-]-�"@��8i#��76�2$�s�c�Ǽ�b�#�F�)b�ō#>e~6��U�<+�F1[���YoP��G�ojx&�|�{г�E~�[�(���㻹���!��2;�	��q�WQ
B�)�q�裀~���r*�ʋ�[F��ͪU?�����nT5=�����翷���
��
��k��d�#S���᚟��A��ɀ�s���;ND�	13
 ����z%Z���_R ���ߦ�1�
�H|XG����1�̣��H(x�X�|v�U�g
m�T*�D�ے���OHQ� 3̧�<��C*"5�̌�E�z2r'���b<�g 8(��0������1���.���$OH���]]ynI�<��q��	���ǴU��~Ua=U�u�� k�{��Т�#�b�.�`p��G�Wy�a�K$V�[&������Q��x�>�^�C��S��)�LpP�Zeh���Z��I��GN�m.����!D�|Vr739εl����p>�j,�A3 ׵;�C2���4vI�͝�%PP���TQ��J��X��/IE�@+�� ��m�w@
X�k1�z-Tɦ+�����/<z�d�o�W�S/O�^��,�!t��6�Z�f����ؖ������}���&)�����a�>ь��c��-���=���3�&�ɝ���"{M����`%���%`S������v,OTs���"�B�Y���&�1�<�sE*j$C��hA�
B�ۡ�R1��|�W����� ��G3�Q#g�ʡv�
V�W��Qi>�L��$n�����,)����л�W��g_���6�W�͗�����_5�^������i�o�g��$3��O���?����j���I����_���/Z�c����y�����U�˝�;����}���?Y[�=#�_�������������5���j���nmw�Vol�v~��?�����ev�Q�_��v��#���\,��\�R���1I�Xb�
[Z��
[�]j�v�'��U��PꚖ[S.�z�;7L�px����/V���w5
�4&(��E�����\�Z4��1]/tky���&�7��6�i���w��B(�>���M�M�8���l�������#�Ȣ�{��Փ#���ˁ�cS��)�Ύ��9R֠�٣�fo����{�$Ah�掣�sDrb�i�LHW��	f�!G������ [	~�]W�����Ҳ��K�b�jz/{5^�U
�@�U���)@:/?����e�X�ˏ�|#j����6�K�#
'88��	� 'nC�H[��
�F���\��uU���q¯��%�g�Ԓ��Q5]V*)4I���(�w�~�z#��:H��T��r���=K�L�z
 ;x��,D>�uq'�pY�+���!��IFwH����FW	U��e��(&2�#B^Y<�R<^2�ѥ��Ѐ��l��\��vl��Z�{,R�ɴ
Jk�u�3���/3�����)�2�X!�d_2"6W$�9kJ�+ؘ����.1	&�p��x�<$h+��&��L�˖l`���	c]X��}n�%[

�<��@�A9~az�=wu#��33?�zx~�'e�GN2���|���9-����Z�T(>����D�y�NYZaF���"��0�N�_���9�clU������Z?!����.�?��ȿ��jq.���)��>�/���>���e?���x�i ̓���K���\�A���}��,n7� $�h��Sw��.�9�o^`5 8Q p��x�u>�I���������*�)�?����(��>��n{F����W�c{ "�Yd�:zW8iƎ� @�9��|�"�h�l������j+��7ҳӖ�����e@����xu������:���>h��Mb^��'d���ȟ8
��3�3��?�f���S)T���<��~��L�����rl���1j`���˕���R|8�/���?m�����i�Y*;Q0k+<C�wt��]N�Jj�1��Q��}��A��֓"�	���۸���JL���?���Z#h����������~�k��G�
��R)y�+_*?���I��j�:O����1������1e�4�uX��\�f9:{��g]t��@@t�<���z��fL�Cv��j/Q�C�`�?8{t��>�DGن�陇~$�K��������>�i�jl�o��ܺ8<���S/��������Y�O>�" ���Gh�\[�?bWx��W�Ť�/�Ѓ�����T�$�5�㢠0��{K�З:Sg�;̞�3����u�L՗I����,����l�e�X�~�y+�2��*����w��H9i.��� ����3k�xK��ls���z���m-{L|��\6û�(���@�B�[
�I�"\��L��;.?�tN��xwm��pytȖY��c9����̣G⼠��=zt��*�|������������Yi�{�=[�
➙}OT�?@����U��B!K4����m��;��<�G2,�^x�+��$;͖�E|�#�.1�/]����#N#���;�l��ڇ^�
�zՌ���6�VęQ�X%i!�����_�2�\��c�{��A������f::,�up�7B���٬��L?˲;*[~����O�ʪt`ODh="��7 )?2-6 �k\��$���T]����!���ƹ	=�LlCD[y��9E����tZZI�d�G��0@��L�u��~b@�3^���QF�pJ���H<q`
�Q���f�q��Cʒ�p.G�-cʬ#u��l��lf�ww�̲gS���1d)x�V��n�W��~ΨT�j�Z�}�ح�b��Z�\��9�P��V�赮V���^,�*'���V�ݹ�1��BY����0��|�M�&����6����;�ם�uo8Z��g4]�h��k�tjA���b��Q-�fG��R�� 4��	$0��o�bT�*�Ή�vؖP���,m@,�X߀0f��E=�%F2KP�E.b%l�+��8�{N�[7W�{@����3Ǒ̓��
�(%z��Չ���1��&�i��gE���S<�;��*p���M�t7�Fp���"����~����5��۸��>k���xn>��L�ԇ�ym� �����U����bA{���ǳZst�c��|�rF*�X߹�͉/zjf��������0�n]&���؋����Д}a�������BߴLO�b�/�����Ok�=��2J|�0�.p�'��Y��x=�c��P7�:�������F��̶4��]�%,`��1���$B��$t垻l���Ʋ��G���3���ks1.}L�O�;e�S-ƹ�U�]���m����8uyI�[zw �!����4LD$�Bh�R��O&�yz�_�����K�J���sSȌ�~�5!���C��c[�f����u6F��]b�.9�q��܆E���-&$��L�i:���:����?�SXd����ʀ8�j��C����9�������o7��
��v�b0�4��L@����@��q<�D=�¡ ��Gw�L�纤�}
������Ҁ+z'rd>�*�VO������}�-�{Ђ�4�u��CE��X�ü�A�Y�,�:v$<���7��=_���<�V�oņ��'L�F�}�"�L�O]�0: ���[���!O^c��zJN�0�ޙ�m��Nl���@�TeIA�Hň�O�����BQ�����mRM�.ԣw�����@���x' &@���7;�<r�-q�-�%R��}F�<L�2�^��[�p��rLS*�m�����F;��G9��_>x �nf�q��ڤGXק;��3��mǄ�]�~��^�}�t��g?PQ�!��c������sDW-Ɩ���>У+}Ӵ{�C�a��|�A�\�0Z��/#K��Q8���&v�,�pb�i�}$�G~�n�ilu��{�1��s��g��H����K�g��[�H#�'`q����G2> �vhp��l#,�@�S��(�k�9v��Gw�8J����.����N7b3j�� ŵ�B>}�����lB��EDۛ���]�G$!�R΢�!s���/�|�!zyI��k��\7�k��wm(��b]�CP y7������E�����P�D �$�X@���#6��lWԍ�̇��9� ���/�Ű'�_Hh�&D.��f�<���}~�������v��p���~KT��玩�[��15Tq�	hY6\����Q�Zd}��v�Q����c��k0�<*���)Ը�j"�/[��(`T���ڢZH���!AJZ���y�rR���ܱ��� �Yj�:�a]��f /"��$Bϼv9k��䰲l/n��m%Դ����*U��r��ޕt)���7�W��M\��o��=4"("L�DTTTT�_�l"*����g2#C��>��9�S|���"�^�bv�_���+�Is�bP���=�
�;�����_C�/��e��o|��99~�
���
ֺ/�)�X���:�����	��_��+���������A��������O=������Kh�	����k��y��h��_��h�;����*�����B�������Q^�U�kC=��
���%���
�� �XN@�� QM����v�z86�ő���$�Y��LS�ͼ@�G�)KEw䔒�_^`�$�f�<p�c��6�-�:o��O�����*�g�s�E06a)�:ݟ<�͐��!����>�O���8��4�y�v8��D>���K��'��S�'����N�¤�\������1�zP��'�]>1F<�l�ٺ����T�؈�{��+���3���=� R�ٞK&ֺ;W�&�n��r�(�>���&L�˽�N�Ո�\�e�����;i!��e�Z.P�����H4 ���K7v�n�ǔ���P�6a�*�L�p��U%�D�P;br/qi��IW��D[�P�{n;%r�8�{	�!K��ہ��rV bry�: ����e}7y�ӓ�iޖNr�N�/t��Y����/�,��\o�b�<���� Я'_��f�P�x �v�bC>�x1d�r���|�JT�E�q��s�t�\��ն�P'9�� ]2UaN���D}vƱp<�9;Q�A�8BV��ɟ�%�R_s^��[s� S�I�.��	�,�(c��Dڞ�7�5���}#$C|����
!��z��'U�.�j�ʑ��r�:c+�J����Xt֞�p�3E�,F��
�=ť��x,�}m4����2A�b0M�Saud����f�?���M�/��4>�}7>��!h�A�����3��2C�M�^����D:�����q������m+���U�f2��:��}����ٷz�XP�Iiɗgv��ii�,` �q��K�l�����v3u2_Ds:���q�j��SGݶ���;K.g��$��`���>�o�q��z���`&QƧ�����
<�R�>�o�W�����v�MLNOC[e�#c���.�=-�ײ�����YZ��4�u��p>�t�g�M!�ƐQs}2�h���rRh��{: e���!�¼����@3��_�����*�!;���j�Y
4A�ׇ��@��c�F�?����+A��: *��?6�C����������'�_��g%h���h��h�l�����B��M��(x�-�wF�
{R�MA��
�e����?����n؟����/��S��)���ﲖ��H���o�Z���L����+��~_K����.
9��B�ӏ�}��}#��c�ǋl��-�Ժg~5�mg�^;�|j_�[o�kX�7f�#n��2ރN�k���JCdVv:�q�m�c,[}9��o�}��}#�S�-��ɥD�����`�B�.U�2�>��8;��u:�m��?�}�ݢ�t{��D�#'�]Rek�s�]+ِB>�D��z�DP��2r(:8�Cgoy͂�&���i��4u�bNuv�ۿ�Ӡ���kC��~�C@M���������
���l0�X���H����O?����?+BE�[|4��!����8�C�_����I������
�� ����?`������B���ڇ�jBE���4������	��c$���P1��➆�	����$�T������?`������l��P@��c�&�?��ׇ����ha�?�� �����������j��O���������?
���XT��?b�����@������"T���4�a��,�L�	��d�\4Mr1��4A8Aq�	��\L21�A{����O��4��+�������CZ���V3��j�N�Q�3c;"K���̤��CKǛD��Ò\��Z�}��U�c����������؍�(.����=�h8���)m�qp�����;�������h���>�������j���o*����7��&��_`�����0����oO�?p�k%�`��%|�@3Q���������������/��+Ae�O��B�e�)�N�`J�:	�œ ��b�E�)C���!:�1"x4�������������W���ik<_���l��i��鶭��S���O�<�FG)x��w�z{KO-)�W�TR�#�v���>bX���|�y����DPz�(�ݰ�-v���͖�0"P.>���Z�m�K�������'�?��_	*��a�#Q�����?a�%���0�������������)�쿡�b���������G�G���$��*P�_�E��-��������'�_�������%4
�@����_#�����a�[B+F#���
�%h��Ǩ'���+������k���������i� �����ߚP���:�Ӆ����_?�?��������m�W�< ���v�Ǳ'���
���o�a�w}�������z�c��[
�T�=����#y�b�z�*

�����Z�sՂ2�
x�KG��ŤNY��Q���l~2�N��B�%N��fԊ�XH��'���=x+�4���.�LnK��l�f�ˍ�Ҳ/��������
3�+T�V�B���4/��0(r�ܟf$_��{��=N�\�ƾ���}�Ǿ�'sߞ/_V����w"�%�[���͖���Y�*�M���4��]���7�N�s6��>f'�j5�P;�0d6��6F)�m��)�{����_�haI�N�u��˰5;�{����v��Q{w֘$�:	�F�?��׆Z��~Y@
�^@����_#�����)���� ���?�����7���z��迚P����s���B��k��_[�5��	�a���+B3�?�qQ�e�p$��s?��"o,�bIQ�s���Qe�������������;�?i��
�E����)�SLڣ�yg8O�S����������XG}����i�-a�E{{�>��3�ùN��6=�ta��|õ�"�il-��51Y�ۜ�Y1:kݾ�e���)��*�p�c��o��������hTq�?���U�F�?����?��������n�Ǳ����U���|>����������������u��w�T>��0�S	*�0��X@����_�G�����U�R��	�ơ��3���* ������������磱���k�&�?���C��>�B#��g�P��������u�?>�����O���*���� ���P��?���4�b(�8~�|}}D1a�>�a�������9�Q��c��
�rL����O��)��_~���ҡW����By���FN�<
@�/��B�����m��Þ�`�_%�����`򷙨�� �OӰ��4��������W�������I 8j�?�����O�h��*P/��������{���o��~������ķ������GQģ���*���{������_/	r�]Qo�w�l���Z��������_Y���%��`5\������� !�E@?�jeqq�2��z��S&o�QY������A�(�3�?qH�&�Ōe�g�Mvv�"�z�s����A^�~cg-s��Q�.�^�Cnu>��ˎ�V�^�V�[N�r:|y�	+T�r�4��Ҡw!ϖ���__;v�9˪��묬�~����
��
�����=,�d��U�s����\���^1qk�΅2�[۷�?��gj��[<�s���kr�K��u)$ߟG򘚠Ę�;�ݞ����@�v�����k��M��W岈&�5���߯��?�Ԇz���r��߁��&��(�ԆF�?���~�/�x
���������B�{��ז�+��}%���s��{�][���������^����kJ�o�5���ty��u$���r�σ�1���Is������.�Ed)��,ŢRBt���t5�U���,�!��k��k5^F�HŢV	���ϋ����y�����ח������n��rZ�����D��f�>*3y���,����ba��\A;Vlqx��`q�o���^}Q��h����Q��֛�H5�L�ѩ�$)��)�ᣨ�.�U�W-�0%)[��n[��!������
���O�T�������PAN�j���ԉ
퍗K��N���vo��V��ƺ+0��;hR�O��9�4ok�!�,IՐ��ImL[g�rij�)�3H�-1?��I���/%�Ţ���RYqS�.+�ڭ�
39]m�����4d�f������F%�l���I.��73����i���v2��+��FS��{�j,��ޱ�u�#Y��i���j5�U��N��I�u����i���4�v��4����3�{N�u����	��g��I��;��I��i>Q(��б��ڛF�6@"-d�Br4)�+�����=l��2��rWS���`C7�`O2�
�d!�����r��_ɤ��by�P\���-yiOA5�۲����ԙq�9¹N��B9}�q�#�91��eKel�:��BY�%q9�w�F2~|�PI��q�M�ݰ�dR\�.�(�L��4j��F
�����bgcKr�2��6fN��aI;�"9��X}DUK'����:������7]L�%�K�Vs���ٵ+��4��Æ�;�ҡ�K#DD
�Q�J�c�9��t����&�y�8��c��N������"�]J}��_����Z�����?k�Z������W����~�ɿQȀO�c�7_����7��_��k��-dZ� W����¡hHA-q!%��G��HU	11��t��b<'�X�Q촰|M��X%�/x�Jݥ�|��/>k��k��~��O��_���ٓ��P@������?�^N`Q����m��߽N��u@%\�<~D��k�O^/�K��kw���*ֵ�ܡ>�C���uW'S�xcV�9�G�`$W��F4ZY�Z��4���J?�<u��3?c7���`lTC�Z��Oƒȹ�>�%)�80p�p�K�F{b.���8�0��J�
=��T;'D�H�U�?9a'�+�F�˔�J_ gk	'��3��zJ�ZS��YK얅�
*���uPY�,l���Tl�{tr�9\&����2"�o�l{*`?ݐ����g�\9C�v����y�0l�ǫD2\V0��d�\�v�����$kI[�0����)}���T7�v�`R��R9��g{��������[�dl˫�mnmFZ�JmGZ�V$���|.������|)�1s�z1�ˉ�T���_.ǳ9�s�I:�ʐ�MדBn|㘰/9�Qy��o4s�5!o�R7��c�(f����A�]BrF*:�Ω�*��$���Q��H5�.��J"���̵�0H���jyqQ�(�oł
^*���A������(%r�2Z���]f������w�V1�
�#�q�2�c�y�B#����-"�2T�^��n�~|���"���AQ���%So�#��,�QR����Mp�ɓ'̛O���w�+6LYm#�kQ�R/�YsԈ��7�d	cSj��m�c;��
�5�����#7cf����3��7�W1��~�T?�n�%��ju�U�qE�61�+2G��_�ۑ�,�-P���lu
��c��`���w�X�c˼�a�A��X��n8e��Fj=�C�b��!Y,�z��w���m�hN�.:r�4Z'@I'0�1 �a�=��wI����~�xk��{�_� 
��B��tf3�ǧ�'�-/<�7T�1��~h����)7��t��օJ/�U�2!~,A7��ףG�i஘��^�IP���ؼ�TP�X��P�7�% ��k���������؉��;a�q/@�Ĥ�hb�~I7��#X��g8�i��3�N���-�kM,��-��Y|����sV7���J��5����o�T�M�o�C�<�
��)d�!���JU
|�v�̶
YG���6�n��K��H��,v�c��D���uّF����N, �t��>P�����߰m�"�����!�~�a�J����ţa���N&I��ao��v���'!��3 �3���ĝ)����:gu����IR�F�p�Fˑh��֢1T��jT�ql�>U$Zq�,1ш�2I�I�G��& ���kS�k�g����m�:�ae��a?���H��o>a�y��]������5�=��p9�3�S��{\Y��5�.&�Inƈ����t7(��~'���g� ��,ն�@>�,|���bǝ&��Π��mׄ���Hs_��9�1|6os�C¾�;.��3��<���O��-0�fo��������?�!���u%�H��a�řx�� ��_$y&,"�.� �G����?��H3�?�`��a�X�BG�f��
���;�����ɿ�jj[:��{[	n.�[;�y�/��s���iZ�uh,lоɼPS*���>ȝ��� C�9��	
��]��-��k�2��|-W��bh���.i`�����	<}�������G退��h���0 %X�
�[�cN�l��>`��!�x`w����qF�_kdz���
G��>�MX�/@��?��?�Or�T�T8�>8|�����ޤ�{����+Ϲ��(_hq�j��}B�o�t��H��j���D�~�����jS7���a?v{��
�P���Q��iMi>�!�)`lp�CQ������&�;U�b�?��^�������V�P�Fj���UB>���v����eh��N��§���K[x[��?��UX����MX�5��:r$�����.�at�9���[�7:�>�lS�\�X�����dDڽs`�C��`�l
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
�V�L6�T-�N(� ,�����*��J-˻�Z����Lkv>
��>/���f���W���
�r��6�������Yʕ�"�ɋ�8�1ս���'�5��Y�;�Q0����]χ7vk�I ��G�2i[�\Y�Vr~eN����s�M��0�J���[B,ۍ�W����j�fu��%ej4e��W�n��KSĂ�#���A�?�v�
�R@�������'���A��?�I� g�X��$��ŀ�#��H�7��������O����#c�z�� �����_7�����|����g�8����#�����J'�t?�1�:����%�+$�=��	���N��Ʀ � �R�����_.ā����������0�_.K%Ǻ�X#-Iu���`�J�m�K;�3�M�T�p�0�g}�̺�V�>U[�MdSW�~���+�0)�a�Z���Z�ۆ�z(r��ړ��,�U���.��Z�u9Wl2�ؐԁ�fI�Ϗ�8��,��K���NO�I��8�9��3�?!E俳@,�����H��3�y�?I�W ����K��c���Bpv�OR|�
�E�?5�C�g����� �?��]x~ā���������#�=q"���_�?�&���.��$�'n��H�|���z �?H������ ������#)>�
D�����8�b��������X��G�0$��Y��� �?H�����_G���;��������X�ϑ�y����8�Nx&���Og���6�� 4Mc�4����΀  ��3F�I'�Fh=�
_�?���Mֱ�?Y֙���Jm9�~�f�b��RB譓��Nz(.��^j��4ʏȥ��=ط����V�HGn{(�*���^���G���O�8�����p�_[�u����?�����������U��{p��_K�ן�O��)�x������rP��)���,��R2Q��hİ�F������1,�4���_���ǐl�A����C�kP���
Z�P��jnYҠ%�}��q��&�4�踞����dn眱[����$v��=;~��>���W�� 3G�P��[!���%���caXw�v3����:��c��n�	�s��*��a�r�i�.�OX6͙.4De%,��Z<~Ը���O��4��l��<�Pm�_+M6�wξИN���$�HR�+$���fL��y��'�<䚡���'����.��6i�6���Q0��}Z;�&��U�Ec���ߐ�Z
j��|�_e�������h
�_��/����/����?����-�S�ߌo�:���Ѱ��|��oo��p�ɍ�ʎ��B�� ��5G�ݭ��3�)+̳���ϔ�ݓ�b�o&�k�r�í�N�%��V���!�E��0�4[�Ӳ�Ѿ1�촠���ۦ̣�z�����?�T�����r����u8�Q�������*C
!͖��P�O���H����5IA��'&:ܸ�H�*'�����85�f���JC-����?����?7H� �P�o�W������w)�����. ���ߛ�߬����|�����Vc�q
�B�M�$�K����+��I�{��ɸ1C~��w}
-ݬS+�U��ۢ�B�	ޡڤ���]y1��#Q5E2�L�x�
j��|��� �������W?���F��A*@��G��i��2 ��a�7��������W��{Z
�8�ѐ�X��}��/$�Ҍ���>�SGxh��;����?u�����������6?&B�o*M�F�,g�3w\�<� E{��M��[�'���@fO��ǔ����$����n!�Y��.&Ǿy�W�,]��o)�c9��Q���Oax�fLŭ�~58�nІ����7���6��)������J_��@�}=����^����|x�e��#�@�W)�����Ms�E����0$���3��V�r��9��.T������A���KAU�]�U�� �����q�����RP%��,~����,����7�u�����.o�w���A�g�[ψw[e�Ǚ;��%��y�g�)o���D���tV��[��r��^"�}����7�Q��m��9���(	�ര�����^7ۑ��7=�&��T�rv���me�덃���4V��vcvc��h �F���2�'i_C��їn�&\��Kl��}J��$l�yo���$���i4��Ϗ)�
���/=M�SA0G��s��_G�Ղ��-���u�#�I,
̨;n��`nV��
36�Z�U���-(�Ϻ��
XLv(�;�1*ۼ3�'���)B.q*�2�������PX�)�wS����3Ϩ#7%ry:�osVOZ��??#�����B
�����_u����$������r�'�`�K)����>D���Z�ѻ����o)x��+^��x?����NSUG���]����x?���_ן��:�����}��U9����W)5f�|T�G�X '�P&tiz2��ɐ'c�]^S�_�~�V��r�ֹF>ں�u���յs~����呲����l�/��u�˹C���.Ol��;������V>�cG2W++4����N��:���B"a�
�r�bD "�Hݍ����`0�>��$�j����NT��#u*v��ͰE�P|(�T�v����6�Q��=��#A���*��{}. *���[�Ղ�I�+BM�. *��ߛ��������Z�?����JA����V��������=���W)���.l{�
�����o����7��W��������Co�'B_�O��&t�w�owX���/���]PO������{�c�+�;���y��{�����w�}߮7����M"�YmS8cJ���"�iH�~��M����}�.Ō^��޴�HR��$�̧y1�B?_����!�����$U:q��;������f�F��]O>���7�E��8n0��me^��'i�X�������k�c�7�L�Ӣ?iy�p6J�1��	C.&=Q��(�5�<]�
�.����k47�k΄U8#�a�9���:�M_՗Vs{R����\�B�A��2T��v�� *���[�Ղ���_j��O�-@��E��o��� �
�h�
���E��!`��"���p�Wc���߼�����	��2 �?0��?0�S��{t�C��+_}�?5|a짶(������	��/u��z�����r���(ԣ1��������w-1��y}fvv����ƽ�`���e�d���F#��8���y?iid;��ı�؉+
vB�?����l��7��
�hR�(��q4����ʠ�I����`�M�Y���]�������,�V�6S�I7��[�!3�4:�b������l�Y��2Z;��9�ͼ&�M��>��8���<>�X}��>%�ݡE��2�v��<a�޼V��aZ�w�x;l��9�h/���^)h���O�+��F�)]uO-��8àP���x���1>J׻�0�_r�K��8s��S�@��	\f�M/��S�ߔI��+�Y'Χ#��؞�wJ����Y��U�yb���=4Pj��Ir�I��+]���f��"W�P�I�\��BU�����z2=^[�]5�
cTHѲ�g�����V�udTF-Nk�TH?W�� Z#��2Ȅ:g�����(��6ja��
��%Y*G{%;�x)O���,3��f]�UԞ	$�L;J��]d�}q��]��#f ��[��?�Eצּ����$4aF����ZBgI�0���	�U,����1�ʪ$I1w�c{��k�����X�������a8�M����S PT
�y>��q��k�
א}��'_�9��O�}�G���aX���у�"������?��<��"r?��߽�|������O�����m�ꂋ!�����_�����/n!�r|m�ߐ|�27hi�-���f2���D-8Y6cP~���se0�ϼf[���2���TU�e�;�%�.�H���O�䌼��q�tp�&�q:L?L��t�C>�~��\;�Sm3�xx�ҳ~�(*�_�1��'�����t�n<��6��Qk��y�t�Zr���p�B6�a�X_�y*�L+�(��r��&R]U1���vfz s�#����G�Zi��_��|����Z�-XϜ�֐�d���8#����*7RG��Ra�#�iIjz�|����|l?
�b�ɂ_�h��LI�'8��R��U�������G��j�᪪Q�*EeҴ�놉uSU\#��,��L�di�$�����~-�������9q#��ϧ�S\yl-���#���k\�7�J�� ��b!)#	���|�t�Hd�������v����WO?~=#�<
�B����Б�4q
�L��=��7:K캑��_o���Fn|~
M-�_��aݝ;<�/ֈT�I &����_�
Eg��(8lx|��?��5�a�gѱ
��������
��s�^!m����u���|����"���B?�#����	*޺4S��H�"E�)R�H�"E�)R�H�"E�)R�H�"E�)R�Hыџ͸- � 