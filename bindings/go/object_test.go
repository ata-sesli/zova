package zova

import (
	"bytes"
	"encoding/hex"
	"errors"
	"path/filepath"
	"testing"
)

func TestObjectIDHelpersAreSHA256Identities(t *testing.T) {
	objectID := ObjectIDFor([]byte("abc"))
	chunkID := ObjectChunkIDFor([]byte("abc"))
	const want = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
	if got := hex.EncodeToString(objectID[:]); got != want {
		t.Fatalf("ObjectIDFor = %s, want %s", got, want)
	}
	if got := hex.EncodeToString(chunkID[:]); got != want {
		t.Fatalf("ObjectChunkIDFor = %s, want %s", got, want)
	}
}

func TestObjectRoundTripRangeAndDelete(t *testing.T) {
	db, err := Create(tempZovaPath(t, "objects"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	fixtures := [][]byte{
		{},
		[]byte("hello from Go objects"),
		{0, 1, 2, 0, 255, 42},
		deterministicBytes(180 * 1024),
	}
	for _, fixture := range fixtures {
		id, err := db.PutObject(fixture)
		if err != nil {
			t.Fatal(err)
		}
		if id != ObjectIDFor(fixture) {
			t.Fatalf("object id mismatch for len %d", len(fixture))
		}
		exists, err := db.HasObject(id)
		if err != nil || !exists {
			t.Fatalf("HasObject = %v, %v", exists, err)
		}
		size, err := db.ObjectSize(id)
		if err != nil || size != uint64(len(fixture)) {
			t.Fatalf("ObjectSize = %d, %v", size, err)
		}
		count, err := db.ObjectChunkCount(id)
		if err != nil {
			t.Fatal(err)
		}
		if len(fixture) == 0 && count != 0 {
			t.Fatalf("empty object chunk count = %d", count)
		}
		if len(fixture) != 0 && count == 0 {
			t.Fatalf("non-empty object chunk count = %d", count)
		}
		got, err := db.GetObject(id)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, fixture) {
			t.Fatalf("GetObject mismatch for len %d", len(fixture))
		}

		full := make([]byte, len(fixture))
		copied, err := db.ReadObjectRange(id, 0, full)
		if err != nil {
			t.Fatal(err)
		}
		if copied != len(fixture) || !bytes.Equal(full[:copied], fixture) {
			t.Fatalf("full range copied=%d len=%d", copied, len(fixture))
		}
		empty := []byte{}
		copied, err = db.ReadObjectRange(id, uint64(len(fixture)), empty)
		if err != nil || copied != 0 {
			t.Fatalf("end empty range copied=%d err=%v", copied, err)
		}
		if len(fixture) > 64*1024 {
			window := make([]byte, 70*1024)
			offset := 12345
			copied, err = db.ReadObjectRange(id, uint64(offset), window)
			if err != nil {
				t.Fatal(err)
			}
			want := fixture[offset : offset+copied]
			if !bytes.Equal(window[:copied], want) {
				t.Fatal("partial range mismatch")
			}
		}
	}

	deletedID, err := db.PutObject([]byte("delete me"))
	if err != nil {
		t.Fatal(err)
	}
	if err := db.DeleteObject(deletedID); err != nil {
		t.Fatal(err)
	}
	exists, err := db.HasObject(deletedID)
	if err != nil || exists {
		t.Fatalf("deleted object exists=%v err=%v", exists, err)
	}
	_, err = db.GetObject(deletedID)
	if !hasStatus(err, StatusObjectNotFound) {
		t.Fatalf("GetObject deleted err=%v", err)
	}
}

func TestObjectManifestLooseChunksAndAssembly(t *testing.T) {
	sender, err := Create(tempZovaPath(t, "sender"))
	if err != nil {
		t.Fatal(err)
	}
	defer sender.Close()

	payload := deterministicBytes(150 * 1024)
	id, err := sender.PutObject(payload)
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := sender.ObjectManifest(id)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.ObjectID != id || manifest.SizeBytes != uint64(len(payload)) {
		t.Fatalf("bad manifest header: %#v", manifest)
	}
	if manifest.Chunker != "fastcdc-v1" || len(manifest.Chunks) == 0 {
		t.Fatalf("bad manifest chunker/chunks: %#v", manifest)
	}

	chunkBytes := make(map[ObjectChunkID][]byte)
	for _, chunk := range manifest.Chunks {
		data, err := sender.GetObjectChunk(chunk.Hash)
		if err != nil {
			t.Fatal(err)
		}
		if uint64(len(data)) != chunk.SizeBytes {
			t.Fatalf("chunk size = %d, want %d", len(data), chunk.SizeBytes)
		}
		chunkBytes[chunk.Hash] = data
	}

	receiver, err := Create(tempZovaPath(t, "receiver"))
	if err != nil {
		t.Fatal(err)
	}
	defer receiver.Close()

	for i := len(manifest.Chunks) - 1; i >= 0; i-- {
		chunk := manifest.Chunks[i]
		if err := receiver.PutObjectChunk(chunk.Hash, chunkBytes[chunk.Hash]); err != nil {
			t.Fatal(err)
		}
		exists, err := receiver.HasObjectChunk(chunk.Hash)
		if err != nil || !exists {
			t.Fatalf("HasObjectChunk = %v, %v", exists, err)
		}
	}

	shuffled := append([]ObjectChunk(nil), manifest.Chunks...)
	for i, j := 0, len(shuffled)-1; i < j; i, j = i+1, j-1 {
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	}
	if err := receiver.AssembleObjectFromChunks(id, uint64(len(payload)), shuffled); err != nil {
		t.Fatal(err)
	}
	got, err := receiver.GetObject(id)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("assembled object mismatch")
	}
	deleted, err := receiver.DeleteObjectChunk(manifest.Chunks[0].Hash)
	if err != nil || deleted {
		t.Fatalf("DeleteObjectChunk referenced = %v, %v", deleted, err)
	}
	if err := receiver.DeleteObject(id); err != nil {
		t.Fatal(err)
	}
	looseBytes := []byte("loose cleanup")
	looseHash := ObjectChunkIDFor(looseBytes)
	if err := receiver.PutObjectChunk(looseHash, looseBytes); err != nil {
		t.Fatal(err)
	}
	deleted, err = receiver.DeleteObjectChunk(looseHash)
	if err != nil || !deleted {
		t.Fatalf("DeleteObjectChunk loose = %v, %v", deleted, err)
	}
}

func TestObjectWriterLifecycle(t *testing.T) {
	db, err := Create(tempZovaPath(t, "writer"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	payload := deterministicBytes(220 * 1024)
	writer, err := db.ObjectWriter()
	if err != nil {
		t.Fatal(err)
	}
	for offset := 0; offset < len(payload); {
		end := offset + 777
		if end > len(payload) {
			end = len(payload)
		}
		if err := writer.Write(payload[offset:end]); err != nil {
			t.Fatal(err)
		}
		offset = end
	}
	id, err := writer.Finish()
	if err != nil {
		t.Fatal(err)
	}
	if id != ObjectIDFor(payload) {
		t.Fatal("writer id mismatch")
	}
	if err := writer.Write([]byte("closed")); !hasStatus(err, StatusObjectWriterClosed) {
		t.Fatalf("Write after Finish err=%v", err)
	}
	got, err := db.GetObject(id)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("writer object mismatch")
	}

	cancelID := ObjectIDFor([]byte("temporary"))
	cancelWriter, err := db.ObjectWriter()
	if err != nil {
		t.Fatal(err)
	}
	if err := cancelWriter.Write([]byte("temporary")); err != nil {
		t.Fatal(err)
	}
	if err := cancelWriter.Cancel(); err != nil {
		t.Fatal(err)
	}
	exists, err := db.HasObject(cancelID)
	if err != nil || exists {
		t.Fatalf("cancelled writer object exists=%v err=%v", exists, err)
	}
	if err := cancelWriter.Cancel(); !hasStatus(err, StatusObjectWriterClosed) {
		t.Fatalf("Cancel after Cancel err=%v", err)
	}

	closeID := ObjectIDFor([]byte("close cleanup"))
	closeWriter, err := db.ObjectWriter()
	if err != nil {
		t.Fatal(err)
	}
	if err := closeWriter.Write([]byte("close cleanup")); err != nil {
		t.Fatal(err)
	}
	if err := closeWriter.Close(); err != nil {
		t.Fatal(err)
	}
	exists, err = db.HasObject(closeID)
	if err != nil || exists {
		t.Fatalf("closed writer object exists=%v err=%v", exists, err)
	}
}

func TestRecordsObjectsAndConvertedDatabases(t *testing.T) {
	db, err := Create(tempZovaPath(t, "records-objects"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	must(t, db.Exec("create table attachments(id integer primary key, object_id blob not null)"))
	id, err := db.PutObject([]byte("record object"))
	if err != nil {
		t.Fatal(err)
	}
	insert, err := db.Prepare("insert into attachments(object_id) values (?1)")
	if err != nil {
		t.Fatal(err)
	}
	must(t, insert.BindBlob(1, id[:]))
	if step, err := insert.Step(); err != nil || step != StepDone {
		t.Fatalf("insert object id = %v, %v", step, err)
	}
	must(t, insert.Close())

	query, err := db.Prepare("select object_id from attachments where id = 1")
	if err != nil {
		t.Fatal(err)
	}
	defer query.Close()
	if step, err := query.Step(); err != nil || step != StepRow {
		t.Fatalf("query object id = %v, %v", step, err)
	}
	stored, ok, err := query.ColumnBlob(0)
	if err != nil || !ok {
		t.Fatalf("stored object id = %v, %v", ok, err)
	}
	var storedID ObjectID
	copy(storedID[:], stored)
	got, err := db.GetObject(storedID)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "record object" {
		t.Fatalf("stored object = %q", got)
	}

	dir := t.TempDir()
	source := filepath.Join(dir, "source.db")
	destination := filepath.Join(dir, "converted.zova")
	createPlainSQLite(t, source)
	if err := ConvertSqliteToZova(source, destination); err != nil {
		t.Fatal(err)
	}
	converted, err := Open(destination)
	if err != nil {
		t.Fatal(err)
	}
	defer converted.Close()
	convertedID, err := converted.PutObject([]byte("converted object"))
	if err != nil {
		t.Fatal(err)
	}
	convertedBytes, err := converted.GetObject(convertedID)
	if err != nil {
		t.Fatal(err)
	}
	if string(convertedBytes) != "converted object" {
		t.Fatalf("converted object = %q", convertedBytes)
	}
	if err := converted.DeleteObject(convertedID); err != nil {
		t.Fatal(err)
	}
	if _, err := converted.GetObject(convertedID); !hasStatus(err, StatusObjectNotFound) {
		t.Fatalf("converted deleted err=%v", err)
	}
}

func deterministicBytes(size int) []byte {
	out := make([]byte, size)
	for i := range out {
		out[i] = byte((i*31 + i/7 + 17) % 251)
	}
	return out
}

func hasStatus(err error, status Status) bool {
	var zerr *Error
	return errors.As(err, &zerr) && zerr.Status == status
}
