NFTLoanFacilitator_flat 是扁平化后的文件

Mythril 运行指令：
docker run --rm `
  -v D:\derniere\Web3Bugs\contracts\106:/tmp `
  -w /tmp `
  mythril/myth analyze /tmp/NFTLoanFacilitator_flat.sol `
    --solv 0.8.12 `
    --execution-timeout 600 `
    -o json `
> mythril-report.json

Slither 运行指令： 
slither .

Foundry Fuzz 运行指令：
forge test --fuzz-runs 1000
forge coverage 
