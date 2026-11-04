package zova

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

var _ io.ReadSeekCloser = (*ObjectSeekableReader)(nil)

func TestObjectSeekableReaderReadsAndSeeks(t *testing.T) {
	db, err := Create(tempZovaPath(t, "seekable"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	payload := deterministicBytes(3<<20 + 4321)
	for _, profile := range []ObjectStorageProfile{ObjectStorageProfileDeduplication, ObjectStorageProfileStreaming} {
		id, err := db.PutObjectWithOptions(payload, ObjectPutOptions{Profile: profile})
		if err != nil {
			t.Fatal(err)
		}
		reader, err := db.ObjectSeekableReader(id)
		if err != nil {
			t.Fatal(err)
		}
		if reader.Size() != int64(len(payload)) {
			t.Fatalf("Size = %d", reader.Size())
		}
		all, err := io.ReadAll(reader)
		if err != nil || !bytes.Equal(all, payload) {
			t.Fatalf("ReadAll = %d bytes, %v", len(all), err)
		}

		for _, seek := range []struct {
			offset int64
			whence int
			want   int64
		}{
			{1<<20 - 3, io.SeekStart, 1<<20 - 3},
			{-10, io.SeekEnd, int64(len(payload)) - 10},
			{-5, io.SeekCurrent, int64(len(payload)) - 11},
		} {
			pos, err := reader.Seek(seek.offset, seek.whence)
			if err != nil || pos != seek.want {
				t.Fatalf("Seek(%d, %d) = %d, %v", seek.offset, seek.whence, pos, err)
			}
			buf := make([]byte, 4)
			if _, err := io.ReadFull(reader, buf); err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(buf, payload[pos:pos+4]) {
				t.Fatalf("bytes at %d differ", pos)
			}
		}
		if _, err := reader.Seek(int64(len(payload))+5, io.SeekStart); err != nil {
			t.Fatal(err)
		}
		if n, err := reader.Read(make([]byte, 4)); n != 0 || err != io.EOF {
			t.Fatalf("read past end = %d, %v", n, err)
		}
		if _, err := reader.Seek(-1, io.SeekStart); err == nil {
			t.Fatal("negative seek succeeded")
		}
		if err := reader.Close(); err != nil {
			t.Fatal(err)
		}
		if err := reader.Close(); err != nil {
			t.Fatal(err)
		}
		if _, err := reader.Read(make([]byte, 1)); !hasStatus(err, StatusObjectReaderClosed) {
			t.Fatalf("read after close = %v", err)
		}
		if err := db.DeleteObject(id); err != nil {
			t.Fatal(err)
		}
	}

	if _, err := db.ObjectSeekableReader(ObjectIDFor([]byte("missing"))); !hasStatus(err, StatusObjectNotFound) {
		t.Fatalf("missing object = %v", err)
	}
}

func TestObjectSeekableReaderServesHTTPRanges(t *testing.T) {
	db, err := Create(tempZovaPath(t, "seekable-http"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	payload := deterministicBytes(2<<20 + 99)
	id, err := db.PutObjectWithOptions(payload, ObjectPutOptions{Profile: ObjectStorageProfileStreaming})
	if err != nil {
		t.Fatal(err)
	}
	reader, err := db.ObjectSeekableReader(id)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	request := httptest.NewRequest(http.MethodGet, "/video", nil)
	request.Header.Set("Range", "bytes=1048570-1048600")
	recorder := httptest.NewRecorder()
	http.ServeContent(recorder, request, "video.bin", time.Time{}, reader)
	if recorder.Code != http.StatusPartialContent {
		t.Fatalf("status = %d", recorder.Code)
	}
	if !bytes.Equal(recorder.Body.Bytes(), payload[1048570:1048601]) {
		t.Fatalf("range body differs: %d bytes", recorder.Body.Len())
	}
}

func TestDatabaseCloseClosesSeekableReaders(t *testing.T) {
	db, err := Create(tempZovaPath(t, "seekable-close"))
	if err != nil {
		t.Fatal(err)
	}
	id, err := db.PutObject([]byte("closed with the database"))
	if err != nil {
		t.Fatal(err)
	}
	reader, err := db.ObjectSeekableReader(id)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := reader.Read(make([]byte, 4)); err == nil {
		t.Fatal("read after database close succeeded")
	}
	if err := reader.Close(); err != nil {
		t.Fatal(err)
	}
}
