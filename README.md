# HPE 3par plugin for Proxmox
This a plugin for Proxmox distribution that supports using plain 3par VLUNs as disks

## Create ssh key

For all storage platforms the distribution of root's ssh key is maintained through Proxmox's cluster wide file system which means you have to create this folder: /etc/pve/priv/3par. In this folder you place the ssh key to use for each HPE 3par storage and the name of the key follows this naming scheme: address_id_rsa. Creating the key is simple. As root do the following:

```
mkdir /etc/pve/priv/3par
ssh-keygen -f /etc/pve/priv/3par/192.168.1.1_id_rsa
```

Create user proxmox on the storage with edit role.

```
$ ssh 3paradm@192.168.1.1
  3paradm's password: ******
cli% createuser -c testpw proxmox all edit 
cli% exit

$ ssh proxmox@192.168.1.1
cli% showuser
     Username Domain    Role   Default
     proxmox     all    edit   N
```

```
cat /etc/pve/priv/3par/192.168.1.1_id_rsa.pub
ssh proxmox@192.168.1.1
  proxmox@192.168.1.1 password: ******
cli% setsshkey
 sshrsa AF5afPdciUTJ0PYzB6msRxFrCuDSqDwPshqWS5tGCFSoSZdE= proxmox pubic key
 SSH public key successfully set!
```

Test HPE 3par connection:

```
ssh -i /etc/pve/priv/zfs/192.168.1.1_id_rsa proxmox@192.168.1.1
The authenticity of host '192.168.1.1 (192.168.1.1)' can't be established.
RSA key fingerprint is 8c:f9:46:5e:40:65:b4:91:be:41:a0:25:ef:7f:80:5f.
Are you sure you want to continue connecting (yes/no)? yes
```

## This is work in progress

All functionality has not yet been implemented. Use with caution
