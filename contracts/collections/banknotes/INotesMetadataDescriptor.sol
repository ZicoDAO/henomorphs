// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IColonyReserveNotes} from "./IColonyReserveNotes.sol";

/**
 * @title INotesMetadataDescriptor
 * @notice Interface for Colony Reserve Notes metadata generation
 * @dev Uses callback pattern - descriptor calls main contract for data
 * @author rutilicus.eth (ArchXS)
 */
interface INotesMetadataDescriptor {
    /**
     * @notice Generate token URI
     * @param notes Main contract address (implements INotesDataProvider)
     * @param tokenId Token ID
     */
    function tokenURI(address notes, uint256 tokenId) external view returns (string memory);

    /**
     * @notice Generate contract URI
     * @param notes Main contract address (implements INotesDataProvider)
     */
    function contractURI(address notes) external view returns (string memory);
}

/**
 * @title INotesDataProvider
 * @notice Interface for ColonyReserveNotes to provide data to metadata descriptor
 * @dev Reuses types from IColonyReserveNotes to avoid duplication
 */
interface INotesDataProvider {
    function getNoteData(uint256 tokenId) external view returns (IColonyReserveNotes.NoteData memory);
    function getDenominationConfig(uint8 denominationId) external view returns (IColonyReserveNotes.DenominationConfig memory);
    function getSeriesConfig(bytes2 seriesId) external view returns (IColonyReserveNotes.SeriesConfig memory);
    function getRarityConfig(IColonyReserveNotes.Rarity rarity) external view returns (IColonyReserveNotes.RarityConfig memory);
    function getCollectionConfig() external view returns (IColonyReserveNotes.CollectionConfig memory);
}
