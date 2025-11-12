#!/bin/bash
# Simple test to verify basic functionality

echo "=== SIMPLE VPC TEST ==="
sudo ./bin/cleanup-all

echo "1. Creating VPC and subnets..."
sudo ./bin/vpcctl create-vpc test 10.50.0.0/16
sudo ./bin/vpcctl add-subnet test public 10.50.1.0/24
sudo ./bin/vpcctl add-subnet test private 10.50.2.0/24

echo ""
echo "2. Testing inter-subnet communication..."
if sudo ip netns exec ns-test-public ping -c 2 10.50.2.2; then
    echo "✅ Inter-subnet: PASS"
else
    echo "❌ Inter-subnet: FAIL"
fi

echo ""
echo "3. Testing NAT..."
sudo ./bin/vpcctl enable-nat test
echo "Testing internet access..."
if sudo ip netns exec ns-test-public ping -c 2 8.8.8.8; then
    echo "✅ NAT: PASS"
else
    echo "❌ NAT: FAIL"
fi

echo ""
echo "4. Testing application deployment..."
sudo ./bin/vpcctl deploy-app test public python
sleep 2
if sudo ip netns exec ns-test-public curl -s http://10.50.1.2:8080 | grep -q "Python HTTP Server"; then
    echo "✅ App deployment: PASS"
else
    echo "❌ App deployment: FAIL"
fi

sudo ./bin/cleanup-all
echo "=== TEST COMPLETE ==="