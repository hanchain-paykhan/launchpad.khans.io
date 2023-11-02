// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract LaunchpadMusiKhanNFT is ERC721URIStorage, Ownable {

    // The constructor stores the hash of the code.
    constructor(string memory _code) ERC721("Lunchpad-MusiKhan NFT", "PAD-MKN") {
        hashedCode = keccak256(abi.encodePacked(_code));
    }

    uint256 public totalSupply; // Variable to store the total number of tokens issued so far.
    bytes32 private hashedCode; // Hashed code (needed for specific function execution).

    // Function to increase totalSupply.
    function addTotalSupply(bytes32 _code) public returns(uint256) {
        require(hashedCode == _code, "Code is not correct");
        totalSupply++;
        return totalSupply;
    }

    // Function to create a new token and assign it to a given address.
    function mint(address _user, uint256 _tokenId, bytes32 _code, string memory _tokenURI) public returns (uint256) {
        // Hash the entered code and compare it with the stored hashed code.
        require(hashedCode == _code, "Code is not correct");

        _mint(_user, _tokenId);  // Create a new token and assign it to a given address.
        _setTokenURI(_tokenId, string(abi.encodePacked("https://gateway.pinata.cloud/ipfs/", _tokenURI))); // Set the URI of the token.
        emit TokenMinted(_user, _tokenId, _tokenURI); // Emit an event to notify that a token has been created.

        return _tokenId;  // Return the new token ID.
    }
    
    // Event that occurs when a token is created.
    event TokenMinted(address indexed user, uint256 tokenId, string tokenURI);
}
