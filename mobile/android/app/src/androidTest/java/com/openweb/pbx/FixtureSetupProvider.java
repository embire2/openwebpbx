package com.openweb.pbx;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.nio.charset.StandardCharsets;
/** Test APK only. Java keeps its separate provider process independent of target Kotlin classes. */
public final class FixtureSetupProvider extends ContentProvider {
    private volatile String ownedPayload;
    public boolean onCreate(){return true;}
    public String getType(Uri uri){return "application/vnd.openwebpbx.config+json";}
    public Cursor query(Uri uri,String[] projection,String selection,String[] args,String order){MatrixCursor c=new MatrixCursor(new String[]{OpenableColumns.DISPLAY_NAME});c.addRow(new String[]{"fixture.openwebpbx"});return c;}
    public ParcelFileDescriptor openFile(Uri uri,String mode) throws java.io.FileNotFoundException {
        if(!"r".equals(mode))throw new java.io.FileNotFoundException();
        String value="{\"type\":\"openwebpbx\",\"version\":1,\"server\":\"https://alpha.example.invalid\",\"extension\":\"100\",\"code\":\"fixture-one-use-code-123456789\"}";
        if("owned".equals(uri.getLastPathSegment())){value=ownedPayload;if(value==null)throw new java.io.FileNotFoundException();}
        final byte[] bytes=value.getBytes(StandardCharsets.UTF_8);
        try{final ParcelFileDescriptor[] pipe=ParcelFileDescriptor.createPipe();new Thread(()->{try(ParcelFileDescriptor.AutoCloseOutputStream out=new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])){out.write(bytes);}catch(Exception ignored){}}).start();return pipe[0];}catch(java.io.IOException e){throw new java.io.FileNotFoundException();}
    }
    public Uri insert(Uri uri,ContentValues values){ownedPayload=values.getAsString("payload");return uri;}
    public int update(Uri uri,ContentValues values,String selection,String[] args){throw new UnsupportedOperationException();}
    public int delete(Uri uri,String selection,String[] args){ownedPayload=null;return 1;}
}
