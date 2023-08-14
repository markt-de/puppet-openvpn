# @summary This define creates the openvpn ca and ssl certificates
#
# @param dn_mode EasyRSA X509 DN mode.
# @param country Country to be used for the SSL certificate
# @param province Province to be used for the SSL certificate
# @param city City to be used for the SSL certificate
# @param organization Organization to be used for the SSL certificate
# @param email Email address to be used for the SSL certificate
# @param common_name Common name to be used for the SSL certificate
# @param group User to drop privileges to after startup
# @param ssl_key_algo SSL Key Algo. ec can enable elliptic curve support. ed uses ed25519 keys
# @param ssl_key_size Length of SSL keys (in bits) generated by this module, used if ssl_key_algo is rsa
# @param ssl_key_curve Define the named curve for the ssl keys, used if ssl_key_algo is ec, ed
# @param key_expire The number of days to certify the server certificate for
# @param ca_expire The number of days to certify the CA certificate for
# @param digest Cryptographic digest to use
# @param key_name Value for name_default variable in openssl.cnf and KEY_NAME in vars
# @param key_ou Value for organizationalUnitName_default variable in openssl.cnf and KEY_OU in vars
# @param key_cn Value for commonName_default variable in openssl.cnf and KEY_CN in vars
# @param tls_auth Determins if a tls key is generated
# @param tls_static_key Determins if a tls key is generated
# @example
#   openvpn::ca {
#     'my_user':
#       server      => 'contractors',
#       remote_host => 'vpn.mycompany.com'
#    }
#
define openvpn::ca (
  Enum['org','cn_only'] $dn_mode                                 = 'org',
  Optional[String] $country                                      = undef,
  Optional[String] $province                                     = undef,
  Optional[String] $city                                         = undef,
  Optional[String] $organization                                 = undef,
  Optional[String] $email                                        = undef,
  String $common_name                                            = 'server',
  Optional[String] $group                                        = undef,
  Enum['rsa', 'ec', 'ed'] $ssl_key_algo                          = 'rsa',
  Integer $ssl_key_size                                          = 2048,
  String $ssl_key_curve                                          = 'secp384r1',
  Integer $ca_expire                                             = 3650,
  Integer $key_expire                                            = 3650,
  Integer $crl_days                                              = 30,
  Enum['md5','sha1','sha256','sha224','sha384','sha512'] $digest = 'sha512',
  Optional[String] $key_cn                                       = undef,
  Optional[String] $key_name                                     = undef,
  Optional[String] $key_ou                                       = undef,
  Boolean $tls_auth                                              = false,
  Boolean $tls_static_key                                        = false,
) {
  if $tls_auth {
    warning('Parameter $tls_auth is deprecated. Use $tls_static_key instead.')
  }

  include openvpn
  $group_to_set = $group ? {
    undef   => $openvpn::group,
    default => $group
  }

  File {
    group => $group_to_set,
  }

  $server_directory = $openvpn::server_directory

  ensure_resource('file', "${server_directory}/${name}", {
      ensure => directory,
      mode   => '0750'
  })

  file { "${server_directory}/${name}/easy-rsa" :
    ensure             => directory,
    recurse            => true,
    links              => 'follow',
    source_permissions => 'use',
    group              => 0,
    source             => "file:${openvpn::easyrsa_source}",
    require            => File["${server_directory}/${name}"],
  }

  file { "${server_directory}/${name}/easy-rsa/revoked":
    ensure  => directory,
    mode    => '0750',
    recurse => true,
    require => File["${server_directory}/${name}/easy-rsa"],
  }

  if versioncmp($openvpn::easyrsa_version, '3') == -1 and
  (versioncmp($openvpn::easyrsa_version, '2') == 1  or
  versioncmp($openvpn::easyrsa_version, '2') == 0 ) {
    if $ssl_key_algo != 'rsa' {
      fail('easy-rsa 2.0 supports only rsa keys.')
    }

    file { "${server_directory}/${name}/easy-rsa/vars":
      ensure  => file,
      mode    => '0550',
      content => template('openvpn/vars.erb'),
      require => File["${server_directory}/${name}/easy-rsa"],
    }

    if $openvpn::link_openssl_cnf {
      File["${server_directory}/${name}/easy-rsa/openssl.cnf"] {
        ensure => link,
        target => "${server_directory}/${name}/easy-rsa/openssl-1.0.0.cnf",
        before => Exec["initca ${name}"],
      }
    }

    exec { "generate dh param ${name}":
      command  => '. ./vars && ./clean-all && ./build-dh',
      timeout  => 20000,
      cwd      => "${server_directory}/${name}/easy-rsa",
      creates  => "${server_directory}/${name}/easy-rsa/keys/dh${ssl_key_size}.pem",
      provider => 'shell',
      require  => File["${server_directory}/${name}/easy-rsa/vars"],
    }

    exec { "initca ${name}":
      command  => '. ./vars && ./pkitool --initca',
      cwd      => "${server_directory}/${name}/easy-rsa",
      creates  => "${server_directory}/${name}/easy-rsa/keys/ca.key",
      provider => 'shell',
      require  => Exec["generate dh param ${name}"],
    }

    exec { "generate server cert ${name}":
      command  => ". ./vars && ./pkitool --server ${common_name}",
      cwd      => "${server_directory}/${name}/easy-rsa",
      creates  => "${server_directory}/${name}/easy-rsa/keys/${common_name}.key",
      provider => 'shell',
      require  => Exec["initca ${name}"],
    }

    exec { "create crl.pem on ${name}":
      command  => ". ./vars && KEY_CN='' KEY_OU='' KEY_NAME='' KEY_ALTNAMES='' openssl ca -gencrl -out ${server_directory}/${name}/crl.pem -config ${server_directory}/${name}/easy-rsa/openssl.cnf",
      cwd      => "${server_directory}/${name}/easy-rsa",
      creates  => "${server_directory}/${name}/crl.pem",
      provider => 'shell',
      require  => Exec["generate server cert ${name}"],
    }
  }
  elsif versioncmp($openvpn::easyrsa_version, '4') == -1 and
  (versioncmp($openvpn::easyrsa_version, '3') == 1 or
  versioncmp($openvpn::easyrsa_version, '3') == 0 ) {
    file { "${server_directory}/${name}/easy-rsa/vars":
      ensure  => file,
      mode    => '0550',
      content => epp('openvpn/vars-30.epp',
        {
          'version'          => $openvpn::easyrsa_version,
          'server_directory' => $server_directory,
          'openvpn_server'   => $name,
          'ssl_key_algo'     => $ssl_key_algo,
          'ssl_key_curve'    => $ssl_key_curve,
          'ssl_key_size'     => $ssl_key_size,
          'ca_expire'        => $ca_expire,
          'key_expire'       => $key_expire,
          'crl_days'         => $crl_days,
          'dn_mode'          => $dn_mode,
          'digest'           => $digest,
          'country'          => $country,
          'province'         => $province,
          'city'             => $city,
          'organization'     => $organization,
          'email'            => $email,
          'key_cn'           => $key_cn,
          'key_ou'           => $key_ou,
        }
      ),
      require => File["${server_directory}/${name}/easy-rsa"],
    }

    if $openvpn::link_openssl_cnf {
      if versioncmp($openvpn::easyrsa_version, '3.0.3') == 1 {
        $default_easyrsa_openssl_conf = 'openssl-easyrsa.cnf'
      }
      else {
        $default_easyrsa_openssl_conf = 'openssl-1.0.cnf'
      }
      File["${server_directory}/${name}/easy-rsa/openssl.cnf"] {
        ensure => link,
        target => "${server_directory}/${name}/easy-rsa/${default_easyrsa_openssl_conf}",
        before => Exec["initca ${name}"],
      }
    }

    $_initca_environment = $dn_mode ? {
      'cn_only' => ["EASYRSA_REQ_CN=${common_name} CA"],
      default   => [],
    }

    exec { "initca ${name}":
      command     => './easyrsa --batch init-pki && ./easyrsa --batch build-ca nopass',
      cwd         => "${server_directory}/${name}/easy-rsa",
      creates     => "${server_directory}/${name}/easy-rsa/keys/ca.crt",
      environment => $_initca_environment,
      provider    => 'shell',
      require     => File["${server_directory}/${name}/easy-rsa/vars"],
    }

    if ($ssl_key_algo == 'rsa') {
      exec { "generate dh param ${name}":
        command  => './easyrsa --batch gen-dh',
        timeout  => 20000,
        cwd      => "${server_directory}/${name}/easy-rsa",
        creates  => "${server_directory}/${name}/easy-rsa/keys/dh.pem",
        provider => 'shell',
        require  => Exec["generate server cert ${name}"],
      }
    }

    exec { "generate server cert ${name}":
      command  => "./easyrsa build-server-full --batch '${common_name}' nopass",
      cwd      => "${server_directory}/${name}/easy-rsa",
      creates  => "${server_directory}/${name}/easy-rsa/keys/private/${common_name}.key",
      provider => 'shell',
      require  => Exec["initca ${name}"],
    }

    file { "${server_directory}/${name}/easy-rsa/keys/ca.crt":
      mode    => '0640',
      require => Exec["initca ${name}"],
    }

    exec { "create crl.pem on ${name}":
      command  => './easyrsa gen-crl',
      cwd      => "${server_directory}/${name}/easy-rsa",
      creates  => "${server_directory}/${name}/easy-rsa/keys/crl.pem",
      provider => 'shell',
      require  => Exec["generate server cert ${name}"],
    }
    -> exec { "copy created crl.pem to ${name} keys directory":
      command  => "cp ${server_directory}/${name}/easy-rsa/keys/crl.pem ${server_directory}/${name}/crl.pem",
      creates  => "${server_directory}/${name}/crl.pem",
      provider => 'shell',
    }
  }
  else {
    fail("unexepected value for EasyRSA version, got '${openvpn::easyrsa_version}', expect between 2.0.0 and 3.x.x.")
  }

  file { "${server_directory}/${name}/easy-rsa/openssl.cnf":
    require => File["${server_directory}/${name}/easy-rsa"],
  }

  file { "${server_directory}/${name}/keys":
    ensure  => link,
    target  => "${server_directory}/${name}/easy-rsa/keys",
    mode    => '0640',
    require => File["${server_directory}/${name}/easy-rsa"],
  }

  file { "${server_directory}/${name}/crl.pem":
    mode    => '0640',
    require => Exec["create crl.pem on ${name}"],
  }

  if $tls_static_key {
    exec { "generate tls key for ${name}":
      command  => 'openvpn --genkey --secret keys/ta.key',
      cwd      => "${server_directory}/${name}/easy-rsa",
      creates  => "${server_directory}/${name}/easy-rsa/keys/ta.key",
      provider => 'shell',
      require  => Exec["generate server cert ${name}"],
    }
  }
}
