#ssh -L $lport:localhost:$rport root@$host
##ssh -L 3000:10.104.0.4:3000 ubuntu@152.42.181.220 -i /Users/tthtlc/.ssh/libcloud-private-key.pem
     filepath="/Users/tthtlc/.ssh/libcloud-private-key.pem"
#ssh -vvvvvv -i /Users/tthtlc/.ssh/libcloud-private-key.pem -L 3000:10.0.16.8:3000 ubuntu@mycw
ssh -vvvvvv -i /Users/tthtlc/.ssh/libcloud-private-key.pem -L 3000:localhost:3000 ubuntu@mycw

##
##Host bastion
##	HostName 47.129.98.230
##	User rocky
##	IdentityFile /home/ubuntu/.ssh/libcloud-private-key.pem
##	IdentitiesOnly yes
##
##Host internal
##	HostName 10.0.16.8
##	User rocky
##
##
