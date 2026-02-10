// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMintConduit
/// @notice Generic interface for conduit-type collections that allow core-based minting
/// @dev Any ERC721 collection implementing this can be used as a mint conduit.
///      The diamond validates ownership, then calls consumeCores to consume the resource.
interface IMintConduit {
    /// @notice Consume cores from a conduit token for minting
    /// @dev Called by the diamond's MintingFacet during mintWithConduit.
    ///      Implementation MUST verify msg.sender is the authorized caller,
    ///      deduct cores, and optionally auto-burn if cores reach 0.
    /// @param tokenId The conduit token ID
    /// @param amount Number of cores to consume (= number of tokens to mint)
    /// @param owner The current owner of the conduit token (for validation)
    /// @return success Whether cores were successfully consumed
    function consumeCores(
        uint256 tokenId,
        uint256 amount,
        address owner
    ) external returns (bool success);

    /// @notice Get available core count for a conduit token
    /// @param tokenId The conduit token ID
    /// @return cores Number of cores available for minting
    function availableCores(uint256 tokenId) external view returns (uint256 cores);

    /// @notice Check if a conduit token is valid and active
    /// @param tokenId The conduit token ID
    /// @return valid Whether the token is active and not expired
    function isConduitValid(uint256 tokenId) external view returns (bool valid);
}
