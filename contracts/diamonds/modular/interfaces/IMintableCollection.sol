// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IMintableCollection
 * @notice Interface for mintable collections with variant support
 * @dev Used by DardionDropManager and MintingFacet for direct minting with tier/variant
 */
interface IMintableCollection {
    /**
     * @notice Mint a token with specific tier and variant
     * @param to Recipient address
     * @param tier Token tier
     * @param variant Token variant
     * @return tokenId The minted token ID
     */
    function mintWithVariant(address to, uint8 tier, uint8 variant) external returns (uint256 tokenId);

    /**
     * @notice Assign variant to an existing token
     * @param tokenId Token ID to assign variant to
     * @param tier Token tier
     * @param variant Variant to assign
     */
    function assignVariant(uint256 tokenId, uint8 tier, uint8 variant) external;

    /**
     * @notice Reset token variant (for rolling)
     * @param tokenId Token ID to reset
     * @param tier Token tier
     */
    function resetVariant(uint256 tokenId, uint8 tier) external;

    /**
     * @notice Get token variant for specific tier
     * @param tokenId Token ID
     * @param tier Token tier
     * @return variant The token's variant for the given tier
     */
    function getTokenVariant(uint256 tokenId, uint8 tier) external view returns (uint8 variant);

    /**
     * @notice Check if token has a variant assigned
     * @param tokenId Token ID
     * @return Whether the token has a variant
     */
    function isTokenVarianted(uint256 tokenId) external view returns (bool);
}
