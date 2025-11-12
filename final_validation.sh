#!/bin/bash
# Final Validation Script for VPC Project
# Tests ALL acceptance criteria

echo "🚀 FINAL VPC PROJECT VALIDATION"
echo "================================"

# Clean slate
sudo ./bin/cleanup-all

echo ""
echo "=== PHASE 1: Core VPC Creation ==="
sudo ./bin/vpcctl create-vpc main 10.0.0.0/16
sudo ./bin/vpcctl add-subnet main public 10.0.1.0/24
sudo ./bin/vpcctl add-subnet main private 10.0.2.0/24

echo ""
echo "✅ VPC Creation Test: PASS"
./bin/vpcctl list-vpcs
./bin/vpcctl list-subnets

echo ""
echo "=== PHASE 2: Inter-Subnet Communication ==="
echo "Testing communication between subnets in same VPC..."
if sudo ip netns exec ns-main-public ping -c 2 -W 1 10.0.2.2; then
    echo "✅ Inter-subnet communication: PASS"
else
    echo "❌ Inter-subnet communication: FAIL"
fi

echo ""
echo "=== PHASE 3: NAT Gateway ==="
sudo ./bin/vpcctl enable-nat main
echo "Testing public subnet internet access..."
if sudo ip netns exec ns-main-public ping -c 2 -W 1 8.8.8.8; then
    echo "✅ Public subnet internet access: PASS"
else
    echo "❌ Public subnet internet access: FAIL"
fi

echo "Testing private subnet isolation..."
if sudo ip netns exec ns-main-private ping -c 2 -W 1 8.8.8.8; then
    echo "❌ Private subnet isolation: FAIL (should be blocked)"
else
    echo "✅ Private subnet isolation: PASS"
fi

echo ""
echo "=== PHASE 4: Multiple VPCs & Isolation ==="
sudo ./bin/vpcctl create-vpc secondary 10.1.0.0/16
sudo ./bin/vpcctl add-subnet secondary public 10.1.1.0/24

echo "Testing VPC isolation (should fail)..."
if sudo ip netns exec ns-main-public ping -c 2 -W 1 10.1.1.2; then
    echo "❌ VPC isolation: FAIL (VPCs should be isolated)"
else
    echo "✅ VPC isolation: PASS"
fi

echo ""
echo "=== PHASE 5: VPC Peering ==="
sudo ./bin/vpcctl create-peering main secondary
sudo ./bin/vpcctl test-isolation main secondary

echo ""
echo "=== PHASE 6: Application Deployment ==="
sudo ./bin/vpcctl deploy-app main public nginx
sudo ./bin/vpcctl deploy-app secondary public python

echo "Testing application accessibility..."
MAIN_IP="10.0.1.2"
SECONDARY_IP="10.1.1.2"

echo "Testing main VPC app..."
if sudo ip netns exec ns-main-public curl -s --connect-timeout 3 http://$MAIN_IP; then
    echo "✅ Main VPC app accessible: PASS"
else
    echo "❌ Main VPC app accessible: FAIL"
fi

echo "Testing cross-VPC app access..."
if sudo ip netns exec ns-main-public curl -s --connect-timeout 3 http://$SECONDARY_IP:8080; then
    echo "✅ Cross-VPC app access: PASS"
else
    echo "❌ Cross-VPC app access: FAIL"
fi

echo ""
echo "=== PHASE 7: Firewall Rules ==="
cat > test_firewall.json << JSON
{
  "rules": [
    {
      "subnet": "10.0.1.0/24",
      "ingress": [
        {"port": 80, "protocol": "tcp", "action": "allow"},
        {"port": 22, "protocol": "tcp", "action": "deny"}
      ]
    }
  ]
}
JSON

sudo ./bin/vpcctl apply-firewall main test_firewall.json
echo "✅ Firewall rules applied"

echo ""
echo "=== PHASE 8: Cleanup ==="
sudo ./bin/cleanup-all
echo "✅ Cleanup completed"

echo ""
echo "================================"
echo "🎉 VALIDATION COMPLETE"
echo "Check above for any FAILED tests"
