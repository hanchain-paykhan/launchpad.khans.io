// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract LaunchpadMusiKhanNftV2 is ERC721URIStorage, Ownable, ReentrancyGuard {

    constructor() ERC721("Lunchpad-MusiKhan-V2 NFT", "PAD-MKN-V2") {}

    uint256 public totalSupply;
    address public minter;
    mapping(uint256 => address) public tokenIdToContractAddress;

    function setMinter(address _address) external onlyOwner nonReentrant {
        minter = _address;
    }

    function addTotalSupply() external nonReentrant returns(uint256) {
        require(msg.sender == minter, "Executive address is different");
        totalSupply++;
        return totalSupply;
    }

    function mint(address _user, uint256 _tokenId, address _tokenAddress, string memory _tokenURI) external nonReentrant returns (uint256) {
        require(msg.sender == minter, "Executive address is different");
        require(_tokenId <= totalSupply, "This tokenId is not ready");

        _safeMint(_user, _tokenId);
        _setTokenURI(_tokenId, string(abi.encodePacked("https://gateway.pinata.cloud/ipfs/", _tokenURI)));
        tokenIdToContractAddress[_tokenId] = _tokenAddress;
        
        emit TokenMinted(_user, _tokenId, _tokenURI);

        return _tokenId;
    }

    function airdrop(address _user, address _tokenAddress, string memory _tokenURI) external onlyOwner nonReentrant returns (uint256) {
        uint256 tokenId = totalSupply + 1;

        _mint(_user, tokenId);
        _setTokenURI(tokenId, string(abi.encodePacked("https://gateway.pinata.cloud/ipfs/", _tokenURI)));
        tokenIdToContractAddress[tokenId] = _tokenAddress;
        totalSupply++;

        emit TokenMinted(_user, tokenId, _tokenURI);

        return tokenId;
    }

    event TokenMinted(address indexed user, uint256 tokenId, string tokenURI);
}